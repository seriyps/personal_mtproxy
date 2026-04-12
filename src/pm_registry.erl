%%%-------------------------------------------------------------------
%% @doc Personal domain registry: DETS persistence + registration
%% @end
%%%-------------------------------------------------------------------

-module(pm_registry).

-behaviour(gen_server).

-export([start_link/0, register/2, revoke/1, list/0, size/0, refresh_fronts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(APP, personal_mtproxy).
-define(DETS_TABLE, pm_subdomains).

-record(state, {dets_ref, front_nodes :: [node()]}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Register a new personal subdomain under BaseDomain.
register(Email, BaseDomain) ->
    gen_server:call(?SERVER, {register, Email, BaseDomain}).

revoke(Subdomain) ->
    gen_server:call(?SERVER, {revoke, Subdomain}).

list() ->
    gen_server:call(?SERVER, list).

size() ->
    case dets:info(?DETS_TABLE, size) of
        undefined -> 0;
        N         -> N
    end.

%% Re-scan all connected nodes, update the front_nodes cache, and replay
%% the full policy table into any newly discovered front nodes.
%% Useful after a split-brain recovery or manual node connection.
refresh_fronts() ->
    gen_server:call(?SERVER, refresh_fronts).

init([]) ->
    {ok, DetsFile} = application:get_env(?APP, dets_file),

    {ok, DetsRef} = dets:open_file(?DETS_TABLE, [{file, DetsFile}, {keypos, 1}]),

    %% Monitor nodes so we can replay the policy table into newly connected
    %% front nodes (relevant in split front/back setup with multiple fronts).
    ok = net_kernel:monitor_nodes(true),

    FrontNodes = lists:filter(fun is_front_node/1, [node() | nodes()]),
    ok = replay_to_nodes(FrontNodes, DetsRef),

    {ok, #state{dets_ref = DetsRef, front_nodes = FrontNodes}}.

handle_call({register, Email, BaseDomain}, _From, State = #state{dets_ref = DetsRef}) ->
    case generate_slug(DetsRef, BaseDomain, 5) of
        {error, Reason} ->
            pm_prometheus:count_inc(personal_mtproxy_registration_total, 1, [error]),
            {reply, {error, Reason}, State};
        Subdomain ->
            {ok, [#{port := Port, secret := BaseSecret} | _]} = application:get_env(mtproto_proxy, ports),
            ok = dets:insert(DetsRef, {Subdomain, Email, erlang:system_time(second)}),
            ok = broadcast_policy(add, Subdomain, State#state.front_nodes),
            pm_prometheus:count_inc(personal_mtproxy_registration_total, 1, [ok]),
            {reply, {ok, Subdomain, Port, BaseSecret}, State}
    end;

handle_call({revoke, Subdomain}, _From, State = #state{dets_ref = DetsRef}) ->
    case dets:lookup(DetsRef, Subdomain) of
        [] ->
            pm_prometheus:count_inc(personal_mtproxy_revocation_total, 1, [not_found]),
            {reply, {error, not_found}, State};
        _ ->
            ok = dets:delete(DetsRef, Subdomain),
            ok = broadcast_policy(del, Subdomain, State#state.front_nodes),
            pm_prometheus:count_inc(personal_mtproxy_revocation_total, 1, [ok]),
            {reply, ok, State}
    end;

handle_call(list, _From, State = #state{dets_ref = DetsRef}) ->
    Entries = dets:match_object(DetsRef, {'_', '_', '_'}),
    {reply, Entries, State};

handle_call(refresh_fronts, _From, State = #state{dets_ref = DetsRef, front_nodes = OldFronts}) ->
    NewFronts = lists:filter(fun is_front_node/1, [node() | nodes()]),
    Added = NewFronts -- OldFronts,
    replay_to_nodes(Added, DetsRef),
    ?LOG_INFO("refresh_fronts: old=~p new=~p added=~p", [OldFronts, NewFronts, Added]),
    {reply, {ok, NewFronts}, State#state{front_nodes = NewFronts}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, Node}, State = #state{dets_ref = DetsRef, front_nodes = FrontNodes}) ->
    %% Check if the new node is a front before adding it to the cache.
    case is_front_node(Node) of
        true ->
            replay_to_nodes([Node], DetsRef),
            {noreply, State#state{front_nodes = [Node | FrontNodes]}};
        false ->
            {noreply, State}
    end;

handle_info({nodedown, Node}, State = #state{front_nodes = FrontNodes}) ->
    {noreply, State#state{front_nodes = lists:delete(Node, FrontNodes)}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{dets_ref = DetsRef}) ->
    ok = dets:close(DetsRef),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private helpers

%% Replay all DETS entries into the policy table on each of the given nodes.
replay_to_nodes(Nodes, DetsRef) ->
    dets:foldl(
      fun({Subdomain, _Email, _Timestamp}, ok) ->
              [policy_rpc(Node, add, Subdomain) || Node <- Nodes],
              ok
      end,
      ok, DetsRef).

%% Broadcast a policy table operation to the cached list of front nodes.
broadcast_policy(Op, Subdomain, FrontNodes) ->
    [policy_rpc(Node, Op, Subdomain) || Node <- FrontNodes],
    ok.

policy_rpc(Node, Op, Subdomain) ->
    try erpc:call(Node, mtp_policy_table, Op, [personal_domains, tls_domain, Subdomain]) of
        ok -> ok
    catch Class:Reason ->
        ?LOG_WARNING("mtp_policy_table:~p(~p) on ~p failed: ~p:~p",
                     [Op, Subdomain, Node, Class, Reason])
    end.

%% A node is a front if mtp_policy_table is running on it.
%% This is cheaper and more direct than inspecting config: it works regardless
%% of node_role setting, app state, or whether mtproto_proxy is installed at all.
is_front_node(Node) ->
    try erpc:call(Node, erlang, whereis, [mtp_policy_table]) of
        Pid when is_pid(Pid) -> true;
        undefined            -> false
    catch _:_ -> false
    end.

generate_slug(DetsRef, BaseDomain, Retries) ->
    case Retries of
        0 ->
            {error, max_retries};
        _ ->
            Slug = [($a + rand:uniform(26) - 1) || _ <- lists:seq(1, 5)],
            Subdomain = list_to_binary(Slug ++ "." ++ BaseDomain),
            case dets:lookup(DetsRef, Subdomain) of
                [] ->
                    Subdomain;
                _ ->
                    pm_prometheus:count_inc(personal_mtproxy_slug_collision_total, 1, []),
                    generate_slug(DetsRef, BaseDomain, Retries - 1)
            end
    end.
