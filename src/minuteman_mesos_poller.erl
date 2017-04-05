%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%% Polls the local mesos agent if {minuteman, agent_polling_enabled} is true
%%%
%%% @end
%%% Created : 16. May 2016 5:06 PM
%%%-------------------------------------------------------------------
-module(minuteman_mesos_poller).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% If we cannot poll the agent for this many seconds, we assume that all the tasks are lost.
-define(AGENT_TIMEOUT_SECS, 60).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([handle_poll_state/2]).
-endif.

-include("minuteman.hrl").
-include_lib("mesos_state/include/mesos_state.hrl").
-define(SERVER, ?MODULE).
-define(VIP_PORT, "VIP_PORT").

-record(state, {
    agent_ip = erlang:error() :: inet:ip4_address(),
    last_poll_time = undefined :: integer() | undefined
}).

-type state() :: #state{}.

-record(vip_be, {
    protocol = erlang:error() :: protocol(),
    vip_ip = erlang:error() :: inet:ip4_address(),
    vip_port = erlang:error() :: inet:port_number(),
    backend_ip = erlang:error() :: inet:ip4_address(),
    backend_port = erlang:error() :: inet:port_number()
}).

-record(vip_be2, {
    protocol = erlang:error() :: protocol(),
    vip_ip = erlang:error() :: inet:ip4_address(),
    vip_port = erlang:error() :: inet:port_number(),
    agent_ip = erlang:error() :: inet:ip4_address(),
    backend_ip = erlang:error() :: inet:ip4_address(),
    backend_port = erlang:error() :: inet:port_number()
}).

-type vip_be() :: #vip_be{}.
-type vip_be2() :: #vip_be2{}.

-type protocol_vip() :: {protocol(), Host :: inet:ip4_address() | string(), inet:port_number()}.
-type protocol_vip_orswot() :: {protocol_vip(), riak_dt_orswot}.
-type vip_string() :: <<_:48, _:_*1>>.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    PollInterval = minuteman_config:agent_poll_interval(),
    timer:send_after(PollInterval, poll),
    AgentIP = mesos_state:ip(),
    {ok, #state{agent_ip = AgentIP}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: state()) ->
    {reply, Reply :: term(), NewState :: state()} |
    {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
    {stop, Reason :: term(), NewState :: state()}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: state()}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: state()}).
handle_info(poll, State) ->
    NewState = maybe_poll(State),
    PollInterval = minuteman_config:agent_poll_interval(),
    {ok, _} = timer:send_after(PollInterval, poll),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: state()) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: state(),
    Extra :: term()) ->
    {ok, NewState :: state()} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

maybe_poll(State) ->
    case minuteman_config:agent_polling_enabled() of
        true ->
            poll(State);
        _ ->
            State
    end.

poll(State = #state{agent_ip = AgentIP}) ->
    Port = minuteman_config:agent_port(),
    case mesos_state_client:poll(AgentIP, Port) of
        {error, Reason} ->
            %% This might generate a lot of messages?
            lager:warning("Unable to poll agent: ~p", [Reason]),
            handle_poll_failure(State);
        {ok, MesosState} ->
            handle_poll_state(MesosState, State)
    end.

%% We've never polled the agent. Or minuteman_mesos_poller has restarted.
handle_poll_failure(State = #state{last_poll_time = undefined}) ->
    State#state{last_poll_time = erlang:monotonic_time()};
handle_poll_failure(State = #state{last_poll_time = LastPollTime}) ->
    Now = erlang:monotonic_time(),
    TimeSinceLastPoll = erlang:convert_time_unit(Now - LastPollTime, native, seconds),
    handle_poll_failure(TimeSinceLastPoll, State).

handle_poll_failure(TimeSinceLastPoll, State) when TimeSinceLastPoll > ?AGENT_TIMEOUT_SECS ->
    handle_poll_changes([], State#state.agent_ip),
    State;
handle_poll_failure(_TimeSinceLastPoll, State) ->
    State.

-spec(handle_poll_state(mesos_state_client:mesos_agent_state(), state()) -> state()).
handle_poll_state(MesosState, State) ->
    VIPBEs = collect_vips(MesosState, State),
    handle_poll_changes(VIPBEs, State#state.agent_ip),
    State#state{last_poll_time = erlang:monotonic_time()}.

-spec(handle_poll_changes([vip_be()], inet:ip4_address()) -> ok | {ok, _}).
handle_poll_changes(VIPBEs, AgentIP) ->
    Ops = generate_ops(AgentIP, VIPBEs),
    maybe_perform_update(Ops).

%% For data consistency, data in new key should always
%% be a super set of data in old key. Therefore,
%% the order of updates is important.

maybe_perform_update({AddOps, DelOps, AddOps2, DelOps2}) ->
    %% first delete from old key
    maybe_perform_ops(?VIPS_KEY, DelOps),
    %% second delete from new key
    maybe_perform_ops(?VIPS_KEY2, DelOps2),
    %% third add to new key
    maybe_perform_ops(?VIPS_KEY2, AddOps2),
    %% last add to old key
    maybe_perform_ops(?VIPS_KEY, AddOps).

maybe_perform_ops(_, []) ->
    ok;
maybe_perform_ops(Key, Ops) ->
    lager:debug("Performing Key: ~p, Ops: ~p", [Key, Ops]),
    {ok, _} = lashup_kv:request_op(Key, {update, Ops}).

%% Generate ops generates ops in a specific order:
%% 1. Add local backends
%% 2. Remove old local backends
%% 3. Remove VIP ORSwots entirely
%% For this reason we have to reverse the ops before applying them
%% Since the way that it generates this results in this list being reversed

generate_ops(AgentIP, AgentVIPs) ->
    FlatAgentVIPs = flatten_vips(AgentVIPs),
    FlatLashupVIPs = flatten_vips(lashup_kv:value(?VIPS_KEY)),
    FlatLashupVIPs2 = flatten_vips(lashup_kv:value(?VIPS_KEY2)),
    FlatLashupVIPsFromThisAgent = filter_vips_from_agent(AgentIP, FlatLashupVIPs, FlatLashupVIPs2),
    {AddOps, DelOps} = generate_add_del_ops(FlatAgentVIPs, FlatLashupVIPsFromThisAgent, FlatLashupVIPs),
    {AddOps2, DelOps2} = generate_add_del_ops(vipbe_to_vipbe2(AgentIP, FlatAgentVIPs),
                             vipbe_to_vipbe2(AgentIP, FlatLashupVIPsFromThisAgent), FlatLashupVIPs2),
    {AddOps, DelOps, AddOps2, DelOps2}.

filter_vips_from_agent(AgentIP, FlatLashupVIPs, FlatLashupVIPs2) ->
    VIPs1 = agent_vips(AgentIP, FlatLashupVIPs),
    VIPs2 = agent_vips(AgentIP, FlatLashupVIPs2),
    ordsets:union(VIPs1, VIPs2).

-spec(agent_vips(inet:ip4_address(), [vip_be()|vip_be2()]) -> [vip_be()]).
agent_vips(AgentIP, VIPBEs) ->
    agent_vips(AgentIP, VIPBEs, []).

agent_vips(_, [], Acc) -> Acc;
agent_vips(AIP, [#vip_be{backend_ip = AIP}=V|R], Acc) -> agent_vips(AIP, R, [V|Acc]);
agent_vips(AIP, [#vip_be2{agent_ip = AIP}=V2|R], Acc) -> agent_vips(AIP, R, [vipbe2_to_vipbe(V2)|Acc]);
agent_vips(AIP, [_|R], Acc) -> agent_vips(AIP, R, Acc).

generate_add_del_ops(FlatAgentVIPs, FlatLashupVIPsFromThisAgent, FlatLashupVIPs) ->
    FlatVIPsToAdd = ordsets:subtract(FlatAgentVIPs, FlatLashupVIPs),
    FlatVIPsToDel = ordsets:subtract(FlatLashupVIPsFromThisAgent, FlatAgentVIPs),
    AddOps = lists:foldl(fun flat_vip_add_fold/2, [], FlatVIPsToAdd),
    DelOps0 = lists:foldl(fun flat_vip_del_fold/2, [], FlatVIPsToDel),
    DelOps1 = add_cleanup_ops(FlatLashupVIPs, FlatVIPsToDel, DelOps0),
    {lists:reverse(AddOps), lists:reverse(DelOps1)}.

-spec(vipbe2_to_vipbe(vip_be2()) -> vip_be()).
vipbe2_to_vipbe(#vip_be2{protocol = Proto, vip_ip = VIP, vip_port = Port,
                backend_ip = BE, backend_port = BPort}) ->
    #vip_be{protocol = Proto, vip_ip = VIP, vip_port = Port,
             backend_ip = BE, backend_port = BPort}.

-spec(vipbe_to_vipbe2(inet:ip4_address(), [vip_be()]) -> [vip_be2()]).
vipbe_to_vipbe2(AgentIP,  FlatVIPs) ->
    [#vip_be2{protocol = Proto, vip_ip = VIP, vip_port = Port,
              agent_ip = AgentIP, backend_ip = BE, backend_port = BPort} ||
        #vip_be{protocol = Proto, vip_ip = VIP, vip_port = Port,
                backend_ip = BE, backend_port = BPort} <- FlatVIPs].

add_cleanup_ops(FlatLashupVIPs, FlatVIPsToDel, Ops0) ->
    ExistingProtocolVIPs = lists:map(fun to_protocol_vip/1, FlatLashupVIPs),
    FlatRemainingVIPs = ordsets:subtract(FlatLashupVIPs, FlatVIPsToDel),
    RemainingProtocolVIPs =  lists:map(fun to_protocol_vip/1, FlatRemainingVIPs),
    GCVIPs = ordsets:subtract(ordsets:from_list(ExistingProtocolVIPs), ordsets:from_list(RemainingProtocolVIPs)),
    lists:foldl(fun flat_vip_gc_fold/2, Ops0, GCVIPs).

flat_vip_gc_fold(VIP, Acc) ->
    Field = {VIP, riak_dt_orswot},
    Op = {remove, Field},
    [Op | Acc].

flat_vip_add_fold(VIPBE = #vip_be{backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {add, {BEIP, BEPort}}},
    [Op | Acc];
flat_vip_add_fold(VIPBE = #vip_be2{agent_ip = AgentIP, backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {add, {AgentIP, {BEIP, BEPort}}}},
    [Op | Acc].

flat_vip_del_fold(VIPBE = #vip_be{backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {remove, {BEIP, BEPort}}},
    [Op | Acc];
flat_vip_del_fold(VIPBE = #vip_be2{agent_ip = AgentIP, backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {remove, {AgentIP, {BEIP, BEPort}}}},
    [Op | Acc].

-spec(to_protocol_vip(vip_be()|vip_be2()) -> protocol_vip()).
to_protocol_vip(#vip_be{vip_ip = VIPIP, protocol = Protocol, vip_port = VIPPort}) ->
    {Protocol, VIPIP, VIPPort};
to_protocol_vip(#vip_be2{vip_ip = VIPIP, protocol = Protocol, vip_port = VIPPort}) ->
    {Protocol, VIPIP, VIPPort}.

-spec(flatten_vips([{VIP :: protocol_vip() | protocol_vip_orswot(),
        [Backend :: ip_port() | ip_ip_port()]}]) -> [vip_be()|vip_be2()]).
flatten_vips(VIPDict) ->
    VIPBEs = lists:flatmap(fun flatten_vips2/1, VIPDict),
    ordsets:from_list(VIPBEs).

flatten_vips2({{VIP, riak_dt_orswot}, Backends}) ->
    flatten_vips2(VIP, Backends, []);
flatten_vips2({VIP, Backends}) ->
    flatten_vips2(VIP, Backends, []).

flatten_vips2(_VIP, [], Acc) -> Acc;
flatten_vips2(VIP = {Protocol, VIPIP, VIPPort}, [{AgentIP, {BEIP, BEPort}}|R], Acc) ->
    VIPBe = #vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol,
                     backend_port = BEPort, backend_ip =  BEIP, agent_ip = AgentIP},
    flatten_vips2(VIP, R, [VIPBe | Acc]);
flatten_vips2(VIP = {Protocol, VIPIP, VIPPort}, [{BEIP, BEPort}|R], Acc) ->
    VIPBe = #vip_be{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol,
                    backend_port = BEPort, backend_ip =  BEIP},
    flatten_vips2(VIP, R, [VIPBe | Acc]).

-spec(unflatten_vips([vip_be()]) -> [{VIP :: protocol_vip(), [Backend :: ip_port()]}]).
unflatten_vips(VIPBes) ->
    VIPBEsDict =
        lists:foldl(
            fun(#vip_be{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                    backend_ip = BEIP},
                Acc) ->
                orddict:append({Protocol, VIPIP, VIPPort}, {BEIP, BEPort}, Acc)
            end,
            orddict:new(),
            VIPBes
        ),
    orddict:map(fun(_Key, Value) -> ordsets:from_list(Value) end, VIPBEsDict).

-spec(collect_vips(MesosState :: mesos_state_client:mesos_agent_state(), State :: state()) ->
    [{VIP :: protocol_vip(), [Backend :: ip_port()]}]).
collect_vips(MesosState, _State) ->
    Tasks = mesos_state_client:tasks(MesosState),
    Tasks1 =
        lists:filter(
            fun
                (#task{statuses = [_TaskStatus = #task_status{healthy = false}|_]}) ->
                    false;
                (#task{state = running}) ->
                    true;
                (_) ->
                    false
            end,
            Tasks),
    VIPBEs = collect_vips_from_tasks_labels(Tasks1, ordsets:new()),
    VIPBEs1 = collect_vips_from_discovery_info(Tasks1, VIPBEs),
    VIPBes2 = lists:usort(VIPBEs1),
    unflatten_vips(VIPBes2).

collect_vips_from_discovery_info([], VIPBEs) ->
    VIPBEs;
collect_vips_from_discovery_info([Task | Tasks], VIPBEs) ->
    VIPBEs1 =
        case catch collect_vips_from_discovery_info(Task) of
            {'EXIT', Reason} ->
                lager:warning("Failed to parse task (discoveryinfo): ~p", [Reason]),
                VIPBEs;
            AdditionalVIPBEs ->
                ordsets:union(ordsets:from_list(AdditionalVIPBEs), VIPBEs)
        end,
    collect_vips_from_discovery_info(Tasks, VIPBEs1).


collect_vips_from_discovery_info(_Task = #task{discovery = undefined}) ->
    [];
collect_vips_from_discovery_info(Task = #task{discovery = #discovery{ports = Ports}}) ->
    collect_vips_from_discovery_info(Ports, Task, []).


-spec(collect_vips_from_discovery_info([mesos_port()], task(), [vip_be()]) -> [vip_be()]).
collect_vips_from_discovery_info([], _Task, Acc) ->
    Acc;
collect_vips_from_discovery_info([Port = #mesos_port{labels = PortLabels}| Ports],
        Task, Acc) ->
    VIPLabels =
        maps:filter(
            fun(Key, _Value) ->
                nomatch =/= binary:match(Key, [<<"VIP">>, <<"vip">>])
            end,
            PortLabels
        ),
    VIPBins = [{VIPBin, Task} || {_, VIPBin} <- maps:to_list(VIPLabels)],
    VIPs = lists:map(fun parse_vip/1, VIPBins),
    BEs = collect_vips_from_discovery_info_fold(PortLabels, VIPs, Port, Task),
    collect_vips_from_discovery_info(Ports, Task, BEs ++ Acc).


-type name_or_ip() :: inet:ip4_address() | {name, Hostname :: binary(), FrameworkName :: framework_name()}.
-type vips() :: {name_or_ip(), inet:port_number()}.
-spec(collect_vips_from_discovery_info_fold(LabelBin :: map(), [vips()], mesos_port(), task()) -> [vip_be()]).
collect_vips_from_discovery_info_fold(_PortLabels, [], _Port, _Task) ->
    [];
collect_vips_from_discovery_info_fold(_PortLabels, _VIPs,
    #mesos_port{protocol = Protocol}, #task{name = TaskName}) when Protocol =/= tcp, Protocol =/= udp ->
    lager:warning("Unsupported protocol ~p in task ~p", [Protocol, TaskName]),
    [];
collect_vips_from_discovery_info_fold(#{<<"network-scope">> := <<"container">>}, VIPs,
    #mesos_port{protocol = Protocol, number = PortNum}, Task) ->
    #task{statuses = [#task_status{container_status = #container_status{
          network_infos = [#network_info{ip_addresses = [#ip_address{
          ip_address = IPAddress}|_]}|_]}}|_]} = Task,
    [#vip_be{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = PortNum,
        backend_ip =  IPAddress} || {VIPIP, VIPPort} <- VIPs];
collect_vips_from_discovery_info_fold(_PortLabels, VIPs,
    #mesos_port{protocol = Protocol, number = PortNum}, Task) ->
    Slave = Task#task.slave,
    #libprocess_pid{ip = AgentIP} = Slave#slave.pid,
    [#vip_be{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = PortNum,
        backend_ip =  AgentIP} || {VIPIP, VIPPort} <- VIPs].

%({binary(),_}) -> {{'name',{binary(),'undefined' | binary()}} | {byte(),byte(),byte(),byte()},'error' | integer()}

-type label_value() :: binary().
-spec(parse_vip({LabelBin :: label_value(), task()}) -> {name_or_ip(), inet:port_number()}).
parse_vip({LabelBin, Task = #task{}}) ->
    [HostBin, PortBin] = binary:split(LabelBin, <<":">>),
    HostStr = binary_to_list(HostBin),
    Host =
        case inet:parse_ipv4_address(HostStr) of
            {ok, HostIP} ->
                HostIP;
            _ ->
                #task{framework = #framework{name = FrameworkName}} = Task,
                {name, {HostBin, FrameworkName}}
        end,
    PortStr = binary_to_list(PortBin),
    {Port, []} = string:to_integer(PortStr),
    true = is_integer(Port),
    {Host, Port}.


collect_vips_from_tasks_labels([], VIPBEs) ->
    VIPBEs;
collect_vips_from_tasks_labels([Task | Tasks], VIPBEs) ->
    VIPBEs1 =
        case catch collect_vips_from_task_labels(Task) of
            {'EXIT', Reason} ->
                lager:warning("Failed to parse task (labels): ~p", [Reason]),
                VIPBEs;
            AdditionalVIPBEs ->
                ordsets:union(ordsets:from_list(AdditionalVIPBEs), VIPBEs)
        end,
    collect_vips_from_tasks_labels(Tasks, VIPBEs1).

collect_vips_from_task_labels(Task = #task{labels = TaskLabels}) ->
    VIPLabelsKeys0 = maps:keys(TaskLabels),

    VIPLabelsKeys1 =
        lists:filter(
            fun(Key) ->
                KeyStr = binary_to_list(Key),
                KeyStrUpper = string:to_upper(KeyStr),
                string:str(KeyStrUpper, ?VIP_PORT) == 1
            end,
            VIPLabelsKeys0
        ),
    collect_vips_from_task_labels_fold(VIPLabelsKeys1, Task, []).


collect_vips_from_task_labels_fold([], _Task, Acc) ->
    Acc;

collect_vips_from_task_labels_fold([VIPLabelKeyBin | VIPLabelKeys],
        Task = #task{labels =  TaskLabels, resources = Resources}, Acc) ->
    Slave = Task#task.slave,
    #libprocess_pid{ip = AgentIP} = Slave#slave.pid,

    VIPLabelStr = binary_to_list(VIPLabelKeyBin),
    TaskPortIdxStr = string:sub_string(VIPLabelStr, string:len(?VIP_PORT) + 1),
    {TaskPortIdx, []} = string:to_integer(TaskPortIdxStr),
    LabelValue = maps:get(VIPLabelKeyBin, TaskLabels),
    {Protocol, VIPIP, VIPPort} = normalize_vip(LabelValue),
    Ports = maps:get(ports, Resources),
    BEPort = lists:nth(TaskPortIdx + 1, Ports),
    VIPBE = #vip_be{
        protocol = Protocol,
        vip_ip = VIPIP,
        vip_port = VIPPort,
        backend_ip = AgentIP,
        backend_port = BEPort
    },
    collect_vips_from_task_labels_fold(VIPLabelKeys, Task, [VIPBE | Acc]).


-spec normalize_vip(vip_string()) -> {tcp | udp, inet:ip4_address(), inet:port_number()} | {error, string()}.
normalize_vip(<<"tcp://", Rest/binary>>) ->
    parse_host_port(tcp, Rest);
normalize_vip(<<"udp://", Rest/binary>>) ->
    parse_host_port(udp, Rest);
normalize_vip(E) ->
    {error, {bad_vip_specification, E}}.

parse_host_port(Proto, Rest) ->
    RestStr = binary_to_list(Rest),
    case string:tokens(RestStr, ":") of
        [HostStr, PortStr] ->
            parse_host_port(Proto, HostStr, PortStr);
        _ ->
            {error, {bad_vip_specification, Rest}}
    end.

parse_host_port(Proto, HostStr, PortStr) ->
    case inet:parse_ipv4_address(HostStr) of
        {ok, Host} ->
            parse_host_port_2(Proto, Host, PortStr);
        {error, einval} ->
            {error, {bad_host_string, HostStr}}
    end.

parse_host_port_2(Proto, Host, PortStr) ->
    case string_to_integer(PortStr) of
        error ->
            {error, {bad_port_string, PortStr}};
        Port ->
            {Proto, Host, Port}
    end.

-spec string_to_integer(string()) -> pos_integer() | error.
string_to_integer(Str) ->
    {Int, _Rest} = string:to_integer(Str),
    Int.

-ifdef(TEST).
fake_state() ->
    #state{agent_ip = {0, 0, 0, 0}}.

overlay_vips_test() ->
    {ok, Data} = file:read_file("testdata/overlay.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
           {tcp, {1, 2, 3, 4}, 5000},
           [
              {{9, 0, 1, 130}, 80}
           ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

two_healthcheck_free_vips_test() ->
    {ok, Data} = file:read_file("testdata/two-healthcheck-free-vips-state.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {4, 3, 2, 1}, 1234},
                [
                    {{33, 33, 33, 1}, 31362},
                    {{33, 33, 33, 1}, 31634}
                ]
        },
        {
            {tcp, {4, 3, 2, 2}, 1234},
                [
                    {{33, 33, 33, 1}, 31215},
                    {{33, 33, 33, 1}, 31290}
                ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state2_test() ->
    {ok, Data} = file:read_file("testdata/state2.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 10, 0, 109}, 8014}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state3_test() ->
    {ok, Data} = file:read_file("testdata/state3.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, 26645}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state4_test() ->
    {ok, Data} = file:read_file("testdata/state4.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, 26645}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state5_test() ->
    {ok, Data} = file:read_file("testdata/state5.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, 26645}
            ]
        },
        {
            {udp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, 26645}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

di_state_test() ->
    {ok, Data} = file:read_file("testdata/state_di.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 8080},
            [
                {{10, 0, 2, 234}, 19426}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).


named_vips_test() ->
    {ok, Data} = file:read_file("testdata/named-base-vips.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {name, {<<"merp">>, <<"marathon">>}}, 5000},
            [
                {{10, 0, 0, 243}, 12049}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

missing_port_test() ->
    {ok, Data} = file:read_file("testdata/missing-port.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [],
    ?assertEqual(Expected, VIPBes).

agent_vips_test() ->
    AgentIP = {1, 1, 1, 1},
    FakeAgentIP = {1, 1, 1, 2},
    VIP1 = {2, 2, 2, 2},
    VIP2 = {2, 2, 2, 3},
    FlatVIPs = [#vip_be2{vip_ip = VIP1, agent_ip = AgentIP, protocol = tcp,
                         vip_port = 5000, backend_ip = {10, 0, 0, 243}, backend_port = 12049},
                #vip_be2{vip_ip = VIP2, agent_ip = FakeAgentIP, protocol = tcp,
                         vip_port = 5000, backend_ip = {10, 0, 0, 243}, backend_port = 12049}],
   FilterVIPs = agent_vips(AgentIP, FlatVIPs),
   Expected = [#vip_be{vip_ip = VIP1, protocol = tcp, vip_port = 5000,
               backend_ip = {10, 0, 0, 243}, backend_port = 12049}],
   ?assertEqual(Expected, FilterVIPs).

filter_vips_test() ->
   AgentIP = {1, 1, 1, 1},
   FlatLashupVIPs = [#vip_be{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                             backend_ip = AgentIP, backend_port = 12049}],
   FilterVIPs = filter_vips_from_agent(AgentIP, FlatLashupVIPs, []),
   Expected = FlatLashupVIPs,
   ?assertEqual(Expected, FilterVIPs).

filter_vips_1_test() ->
   AgentIP = {1, 1, 1, 1},
   FlatLashupVIPs = [#vip_be{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                             backend_ip = AgentIP, backend_port = 12049}],
   FlatLashupVIPs2 = [#vip_be2{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                               agent_ip = AgentIP, backend_ip = AgentIP, backend_port = 12049}],
   FilterVIPs = filter_vips_from_agent(AgentIP, FlatLashupVIPs, FlatLashupVIPs2),
   Expected = FlatLashupVIPs,
   ?assertEqual(Expected, FilterVIPs).

filter_vips_2_test() ->
   AgentIP = {1, 1, 1, 1},
   FlatLashupVIPs = [#vip_be{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                             backend_ip = {10, 0, 0, 243}, backend_port = 12049}],
   FlatLashupVIPs2 = [#vip_be2{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                               agent_ip = AgentIP, backend_ip = {10, 0, 0, 243}, backend_port = 12049}],
   FilterVIPs = filter_vips_from_agent(AgentIP, FlatLashupVIPs, FlatLashupVIPs2),
   Expected = FlatLashupVIPs,
   ?assertEqual(Expected, FilterVIPs).

flatten_vips_test() ->
   VIPDict = [
        {
            {tcp, {2, 2, 2, 2}, 5000},
            [
                {{1, 1, 1, 1}, {{10, 0, 0, 243}, 12049}}
            ]
        }
    ],
    FlatVIPs = flatten_vips(VIPDict),
    Expected = [#vip_be2{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                         agent_ip = {1, 1, 1, 1}, backend_port = 12049, backend_ip = {10, 0, 0, 243}}],
    ?assertEqual(Expected, FlatVIPs).
-endif.

