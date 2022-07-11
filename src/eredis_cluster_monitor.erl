%% @doc This module manages the slot mapping. In a Redis cluster, each key
%% belongs to a slot and each slot belongs to a Redis master node.
%%
%% This module is mainly internal, but some functions are documented and may be
%% useful for advanced scenarios.
%%
%% @see eredis_cluster
-module(eredis_cluster_monitor).
-behaviour(gen_server).

%% Internal API.
-export([start_link/0]).
-export([connect/2, disconnect/1]).
-export([refresh_mapping/1, async_refresh_mapping/1]).
-export([get_state/0, get_state_version/1]).
-export([get_pool_by_slot/1, get_pool_by_slot/2]).
-export([get_all_pools/1]).

%% Public API.
-export([get_all_pools/0]).
-export([get_cluster_slots/0, get_cluster_nodes/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Type definition.
-include("eredis_cluster.hrl").

-record(state, {
    init_nodes   = [] :: [#node{}],
    slots_maps   = {} :: tuple(), %% whose elements are #slots_map{}
    node_options = [] :: options(),
    version      = 0  :: integer()
}).

-define(SLOTS, eredis_cluster_monitor_slots).

%% API.
%% @private
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
connect(InitServers, Options) ->
    gen_server:call(?MODULE, {connect, InitServers, Options}).

%% @private
disconnect(PoolNodes) ->
    gen_server:call(?MODULE, {disconnect, PoolNodes}).

%% @private
refresh_mapping(Version) ->
    gen_server:call(?MODULE, {reload_slots_map, Version}).

%% @private
async_refresh_mapping(Version) ->
    gen_server:cast(?MODULE, {reload_slots_map, Version}).

%% @private
-spec get_state() -> #state{}.
get_state() ->
    io:format("[monitor] ets will be lookup~n"),
    case ets:lookup(?MODULE, cluster_state) of
        [{cluster_state, State}] ->
            State;
        [] ->
            #state{}
    end.

%% @private
get_state_version(State) ->
    State#state.version.

%% @private
-spec get_all_pools() -> [atom()].
get_all_pools() ->
    get_all_pools(get_state()).

%% @private
-spec get_all_pools(State :: #state{}) -> [atom()].
get_all_pools(State) ->
    SlotsMapList = tuple_to_list(State#state.slots_maps),
    lists:usort([SlotsMap#slots_map.node#node.pool || SlotsMap <- SlotsMapList,
                    SlotsMap#slots_map.node =/= undefined]).

%% =============================================================================
%% @private
%% @doc Get cluster pool by slot.
%% @end
%% =============================================================================
-spec get_pool_by_slot(Slot :: integer()) ->
    {PoolName :: atom() | undefined, Version :: integer()}.
get_pool_by_slot(Slot) ->
    State = get_state(),
    get_pool_by_slot(Slot, State).

%% @private
%% Supply a state to prevent an extra ets lookup
-spec get_pool_by_slot(Slot :: integer(), State :: #state{}) ->
    {PoolName :: atom() | undefined, Version :: integer()}.
get_pool_by_slot(Slot, State) ->
    try
        [{_, Index}] = ets:lookup(?SLOTS, Slot),
        Cluster = element(Index, State#state.slots_maps),
        if
            Cluster#slots_map.node =/= undefined ->
                {Cluster#slots_map.node#node.pool, State#state.version};
            true ->
                {undefined, State#state.version}
        end
    catch
        _:_ ->
            {undefined, State#state.version}
    end.

%% =============================================================================
%% @doc Connect to a init node and get the slot distribution of nodes.
%% @end
%% =============================================================================
-spec reload_slots_map(State::#state{}) -> NewState::#state{}.
reload_slots_map(State) ->
    OldSlotsMaps = tuple_to_list(State#state.slots_maps),

    Options = get_current_options(State),
    ClusterSlots = get_cluster_slots(State, Options),
    NewSlotsMaps = parse_cluster_slots(ClusterSlots, Options),
    %% Find old slots_maps with nodes still in use.
    CommonInOldMap = lists:flatmap(
                       fun(#slots_map{node = Node} = OldElem) ->
                               [OldElem || Elem <- NewSlotsMaps,
                                           Elem#slots_map.node#node.address == Node#node.address,
                                           Elem#slots_map.node#node.port    == Node#node.port,
                                           Elem#slots_map.node#node.options == Node#node.options]
                       end, OldSlotsMaps),

    %% Disconnect non-used nodes
    RemovedFromOldMap = remove_list_elements(OldSlotsMaps, CommonInOldMap),
    [close_connection(SlotsMap) || SlotsMap <- RemovedFromOldMap],

    %% Connect to new nodes
    ConnectedSlotsMaps = connect_all_slots(NewSlotsMaps),
    create_slots_cache(ConnectedSlotsMaps),
    NewState = State#state{
        slots_maps = list_to_tuple(ConnectedSlotsMaps),
        version = State#state.version + 1
    },

    true = ets:insert(?MODULE, [{cluster_state, NewState}]),

    NewState.

%% =============================================================================
%% @doc Removes all elements (including duplicates) of Ys from Xs.
%% Xs and Ys can be unordered and contain duplicates.
%% @end
%% =============================================================================
-spec remove_list_elements(Xs::[term()], Ys::[term()]) -> [term()].
remove_list_elements(Xs, Ys) ->
    Set = gb_sets:from_list(Ys),
    [E || E <- Xs, not gb_sets:is_element(E, Set)].

%% =============================================================================
%% @doc Get cluster slots information.
%% @end
%% =============================================================================
-spec get_cluster_slots() -> [[bitstring() | [bitstring()]]].
get_cluster_slots() ->
    State = get_state(),
    Options = get_current_options(State),
    get_cluster_slots(State, Options).

%% @private
get_cluster_slots(State, Options) ->
    Query = ["CLUSTER", "SLOTS"],
    FailFn = fun get_cluster_slots_from_single_node/1,
    get_cluster_info(State, Options, Query, FailFn).

%% =============================================================================
%% @doc Get cluster nodes information.
%% Returns a list of node elements, each in the form:
%%
%% <pre>[id, ip:port@cport, flags, master, ping-sent, pong-recv, config-epoch, link-state, Slot1, ..., SlotN]
%% </pre>
%%
%% See: https://redis.io/commands/cluster-nodes#serialization-format
%% @end
%% =============================================================================
-spec get_cluster_nodes() -> [[bitstring()]].
get_cluster_nodes() ->
    State = get_state(),
    Options = get_current_options(State),
    get_cluster_nodes(State, Options).

%% @private
-spec get_cluster_nodes(State :: #state{}, Options :: options()) -> [[bitstring()]].
get_cluster_nodes(State, Options) ->
    Query = ["CLUSTER", "NODES"],
    FailFn = fun(_Node) -> "" end, %% No default data to use when query fails
    ClusterNodes = get_cluster_info(State, Options, Query, FailFn),
    %% Parse result into list of element lists
    NodesInfoList = binary:split(iolist_to_binary(ClusterNodes), <<"\n">>, [global, trim]),
    lists:foldl(fun(Node, Acc) ->
                        Acc ++ [binary:split(Node, <<" ">>, [global, trim])]
                end, [], NodesInfoList).

%% =============================================================================
%% @private
%% @doc Fetch cluster information from an already connected node or from an init
%%      node if no nodes are connected. Throws an exception if everything fails.
%% @end
%% =============================================================================

-spec get_cluster_info(State :: #state{}, Options :: options(), Query :: list(),
                       FailFn :: fun((#node{}) -> iodata())) ->
          iodata().
get_cluster_info(State, Options, Query, FailFn) ->
    %% First try to use existing connections in pools found in the slot map
    case get_cluster_info_from_existing_pools(State#state.slots_maps, Options,
                                              Query, FailFn) of
        {ok, Result} ->
            Result;
        _Error ->
            %% No usable pool connected. Connect to init nodes.
            get_cluster_info_from_init_nodes(State#state.init_nodes, Options,
                                             Query, FailFn, [])
    end.

-spec get_cluster_info_from_existing_pools(SlotMaps :: tuple(),
                                           Options  :: options(),
                                           Query    :: list(),
                                           FailFn   :: fun((#node{}) -> list())) ->
          {ok, list()} | {error, no_connection}.
get_cluster_info_from_existing_pools(SlotMaps, Options, Query, FailFn) ->
    get_cluster_info_from_existing_pools(SlotMaps, Options, Query, FailFn, {1, #{}}).

get_cluster_info_from_existing_pools(SlotMaps, Options, Query, FailFn, SlotMapIterator) ->
    case next_node_in_slots_maps(SlotMaps, Options, SlotMapIterator) of
        {ok, Node, NewSlotMapIterator} ->
            Transaction = fun(Connection) ->
                                  get_cluster_info_from_connection(Connection, Query, FailFn, Node)
                          end,
            try
                {ok, _Result} = poolboy:transaction(Node#node.pool, Transaction)
            catch
                _:_ ->
                    get_cluster_info_from_existing_pools(SlotMaps, Options, Query, FailFn, NewSlotMapIterator)
            end;
        none ->
            {error, no_connection}
    end.

%% Get next node from a tuple of slots maps, using an iterator tuple to remember what's next
-spec next_node_in_slots_maps(SlotsMaps :: tuple(),
                              Options   :: options(),
                              Iterator  :: {Index             :: pos_integer(),
                                            AttemptedPoolsMap :: #{atom() => true}}) ->
          {ok, Node :: #node{}, NextIterator :: {NextIndex            :: pos_integer(),
                                                 NewAttemptedPoolsMap :: #{atom() => true}}} |
          none.
next_node_in_slots_maps(SlotsMaps, Options, {Index, AttemptedPoolsMap})
  when Index =< tuple_size(SlotsMaps) ->
    SlotsMap = element(Index, SlotsMaps),
    case SlotsMap of
        #slots_map{node = Node = #node{options = Options,
                                       pool    = Pool}} ->
            case maps:is_key(Pool, AttemptedPoolsMap) of
                true ->
                    %% This pool has been returned before. Try next.
                    next_node_in_slots_maps(SlotsMaps, Options, {Index + 1, AttemptedPoolsMap});
                false ->
                    %% It's usable.
                    NextIterator = {Index + 1, AttemptedPoolsMap#{Pool => true}},
                    {ok, Node, NextIterator}
            end;
        _NotUsable ->
            %% Options mismatch or node not a record. Try next.
            next_node_in_slots_maps(SlotsMaps, Options, {Index + 1, AttemptedPoolsMap})
    end;
next_node_in_slots_maps(_SlotsMaps, _Options, _Iterator) ->
    none.

%% Connect to an init node, fetch cluster info and disconnect again
get_cluster_info_from_init_nodes([], _Options, _Query, _FailFn, ErrorList) ->
    throw({reply, {error, {cannot_connect_to_cluster, ErrorList}}, #state{}});
get_cluster_info_from_init_nodes([Node|Nodes], Options, Query, FailFn, ErrorList) ->
    case safe_eredis_start_link(Node#node.address, Node#node.port, Options) of
        {ok, Connection} ->
            try get_cluster_info_from_connection(Connection, Query, FailFn, Node) of
                {ok, Result} ->
                    Result;
                Reason ->
                    get_cluster_info_from_init_nodes(Nodes, Options, Query, FailFn,
                                                     [{Node, Reason} | ErrorList])
            after
                io:format("[monitor] eredis_stop being called~n"),
                eredis:stop(Connection)
            end;
        Reason ->
            io:format("[monitor] Reason being called, Reason: ~s", [Reason]),
            get_cluster_info_from_init_nodes(Nodes, Options, Query, FailFn,
                                             [{Node, Reason} | ErrorList])
    end.

-spec get_cluster_info_from_connection(Connection :: pid(),
                                       Query      :: list(),
                                       FailFn     :: fun((#node{}) -> list()),
                                       Node       :: #node{}) ->
          ClusterInfo :: redis_simple_result().
get_cluster_info_from_connection(Connection, Query, FailFn, Node) ->
    io:format("[monitor] eredis being queried for connection~n"),
    try eredis:q(Connection, Query) of
        {ok, ClusterInfo} ->
            {ok, ClusterInfo};
        {error, <<"ERR unknown command 'CLUSTER'">>} ->
            {ok, FailFn(Node)};
        {error, <<"ERR This instance has cluster support disabled">>} ->
            {ok, FailFn(Node)};
        OtherError ->
            OtherError
    catch
        exit:{timeout, {gen_server, call, _}} ->
            {error, timeout}
    end.

-spec get_cluster_slots_from_single_node(#node{}) ->
    [[bitstring() | [bitstring()]]].
get_cluster_slots_from_single_node(Node) ->
    [[<<"0">>, integer_to_binary(?REDIS_CLUSTER_HASH_SLOTS-1),
    [list_to_binary(Node#node.address), integer_to_binary(Node#node.port)]]].

-spec parse_cluster_slots(ClusterInfo::[[bitstring() | [bitstring()]]],
                          Options::options()) -> [#slots_map{}].
parse_cluster_slots(ClusterInfo, Options) ->
    SlotsMaps = parse_cluster_slots(ClusterInfo, 1, []),
    %% Save current options in each new SlotsMaps
    [SlotsMap#slots_map{node=SlotsMap#slots_map.node#node{options = Options}} ||
                       SlotsMap <- SlotsMaps].

parse_cluster_slots([[StartSlot, EndSlot | [[Address, Port | _] | _]] | T], Index, Acc) ->
    SlotsMap =
        #slots_map{
            index = Index,
            start_slot = binary_to_integer(StartSlot),
            end_slot = binary_to_integer(EndSlot),
            node = #node{
                address = binary_to_list(Address),
                port = binary_to_integer(Port)
            }
        },
    parse_cluster_slots(T, Index + 1, [SlotsMap | Acc]);
parse_cluster_slots([], _Index, Acc) ->
    lists:reverse(Acc).

%% =============================================================================
%% @doc Collect options set via application configs or in connect/2
%% @end
%% =============================================================================
-spec get_current_options(State::#state{}) -> options().
get_current_options(State) ->
    Env = application:get_all_env(eredis_cluster),
    lists:ukeysort(1, State#state.node_options ++ Env).

%%%------------------------------------------------------------
-spec close_connection_with_nodes(SlotsMaps::[#slots_map{}],
                                  Pools::[atom()]) -> [#slots_map{}].
%%%
%%% Close the connection related to specified Pool node.
%%%------------------------------------------------------------
close_connection_with_nodes(SlotsMaps, Pools) ->
    lists:foldl(fun(Map, AccMap) ->
                        case lists:member(Map#slots_map.node#node.pool,
                                          Pools) of
                            true ->
                                close_connection(Map),
                                AccMap;
                            false ->
                                [Map|AccMap]
                        end
                end, [], SlotsMaps).

-spec close_connection(#slots_map{}) -> ok.
close_connection(SlotsMap) ->
    Node = SlotsMap#slots_map.node,
    if
        Node =/= undefined ->
            try eredis_cluster_pool:stop(Node#node.pool) of
                _ ->
                    ok
            catch
                _ ->
                    ok
            end;
        true ->
            ok
    end.

-spec connect_node(#node{}) -> #node{} | undefined.
connect_node(Node) ->
    case eredis_cluster_pool:create(Node#node.address,
                                    Node#node.port,
                                    Node#node.options) of
        {ok, Pool} ->
            Node#node{pool=Pool};
        _ ->
            undefined
    end.

safe_eredis_start_link(Address, Port, Options) ->
    process_flag(trap_exit, true),
    io:format("[monitor] eredis start_link~n"),
    Result = eredis:start_link(Address, Port, Options),
    process_flag(trap_exit, false),
    Result.

-spec create_slots_cache([#slots_map{}]) -> true.
create_slots_cache(SlotsMaps) ->
  SlotsCache = [[{Index, SlotsMap#slots_map.index}
        || Index <- lists:seq(SlotsMap#slots_map.start_slot,
            SlotsMap#slots_map.end_slot)]
        || SlotsMap <- SlotsMaps],
  SlotsCacheF = lists:flatten(SlotsCache),
  ets:insert(?SLOTS, SlotsCacheF).

-spec connect_all_slots([#slots_map{}]) -> [#slots_map{}].
connect_all_slots(SlotsMapList) ->
    [SlotsMap#slots_map{node=connect_node(SlotsMap#slots_map.node)} ||
        SlotsMap <- SlotsMapList].

-spec connect_([{Address :: string(), Port :: integer()}],
               Options :: options(), State :: #state{}) -> #state{}.
connect_([], _Options, State) ->
    State;
connect_(InitNodes, Options, State) ->
    io:format("[monitor] connect started~n"),
    NewState = State#state{
        init_nodes = [#node{address = A, port = P} || {A, P} <- InitNodes],
        node_options = Options
    },

    A = reload_slots_map(NewState),
    io:format("[monitor] connect finished~n"),
    A.

-spec disconnect_(PoolNodes :: [atom()], State :: #state{}) -> #state{}.
disconnect_([], State) ->
    State;
disconnect_(PoolNodes, State) ->
    SlotsMaps = tuple_to_list(State#state.slots_maps),

    NewSlotsMaps = close_connection_with_nodes(SlotsMaps, PoolNodes),

    ConnectedSlotsMaps = connect_all_slots(NewSlotsMaps),
    create_slots_cache(ConnectedSlotsMaps),

    NewState = State#state{
                 slots_maps = list_to_tuple(ConnectedSlotsMaps),
                 version = State#state.version + 1
                },
    true = ets:insert(?MODULE, [{cluster_state, NewState}]),
    NewState.

%% gen_server.

%% @private
init(_Args) ->
    io:format("[monitor] started init~n"),
    timer:sleep(3000),
    io:format("[monitor] init slept 3s~n"),
    ets:new(?MODULE, [protected, set, named_table, {read_concurrency, true}]),
    io:format("[monitor] first ets table created~n"),
    ets:new(?SLOTS, [protected, set, named_table, {read_concurrency, true}]),
    io:format("[monitor] second ets table created~n"),
    InitNodes = application:get_env(eredis_cluster, init_nodes, []),
    AResponse={ok, connect_(InitNodes, [], #state{})}, %% get_env options read later in callstack
    io:format("[monitor]init finished~n"),
    Working = ets:member(?MODULE),
    io:format("[monitor]ets table is working fine? ~s ~n", [Working]),
    AResponse.


%% @private
handle_call({reload_slots_map, Version}, _From, #state{version=Version} = State) ->
    {reply, ok, reload_slots_map(State)};
handle_call({reload_slots_map, _}, _From, State) ->
    %% Mismatching version. Slots map already reloaded.
    {reply, ok, State};
handle_call({connect, InitServers, Options}, _From, State) ->
    {reply, ok, connect_(InitServers, Options, State)};
handle_call({disconnect, PoolNodes}, _From, State) ->
    {reply, ok, disconnect_(PoolNodes, State)};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @private
handle_cast({reload_slots_map, Version}, #state{version = Version} = State) ->
    {noreply, reload_slots_map(State)};
handle_cast({reload_slots_map, _OldVersion}, State) ->
    %% Mismatching version. Slots map already reloaded.
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
