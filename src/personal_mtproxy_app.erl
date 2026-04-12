%%%-------------------------------------------------------------------
%% @doc personal_mtproxy application start handler
%% @end
%%%-------------------------------------------------------------------

-module(personal_mtproxy_app).

-behaviour(application).

-export([start/2, stop/1, config_change/3]).
-export([sni_fun/1]).

-include_lib("kernel/include/logger.hrl").

-define(APP, personal_mtproxy).
-define(LISTENER, https_listener).
-define(METRICS_LISTENER, metrics_listener).

start(_StartType, _StartArgs) ->
    case validate_mtproto_ports() of
        ok ->
            ok = pm_prometheus:init(),

            Res = {ok, _} = personal_mtproxy_sup:start_link(),

            {CowboyIp, CowboyPort, Kind} = cowboy_listen_addr(),

            Vhosts = read_vhosts(),
            #{ssl_cert := DefCert, ssl_key := DefKey} = hd(Vhosts),

            {ok, DetsFile} = application:get_env(?APP, dets_file),
            ok = filelib:ensure_dir(DetsFile),

            cowboy:start_tls(
              ?LISTENER,
              [{port, CowboyPort}, {ip, CowboyIp},
               {certfile, DefCert}, {keyfile, DefKey},
               {sni_fun, fun ?MODULE:sni_fun/1}],
              #{env => #{dispatch => routes()}}
            ),

            Domains = [maps:get(domain, V) || V <- Vhosts],
            ?LOG_INFO("Personal MTProto Proxy UI on https://~s:~p (vhosts: ~p)",
                      [hd(Domains), CowboyPort, Domains]),

            case Kind of
                fronting ->
                    {ok, [#{port := ProxyPort} | _]} = application:get_env(mtproto_proxy, ports),
                    ?LOG_INFO("To open UI via domain fronting, use https://<domain>:~p", [ProxyPort]),
                    ok = add_vhost_domains(Vhosts);
                explicit ->
                    ok
            end,

            ok = start_metrics_listener(),

            Res;
        {error, Reason} ->
            ?LOG_ERROR("mtproto_proxy port validation failed: ~p", [Reason]),
            {error, Reason}
    end.

stop(_State) ->
    cowboy:stop_listener(?LISTENER),
    stop_metrics_listener(),
    case cowboy_listen_addr() of
        {_, _, fronting} ->
            Vhosts = read_vhosts(),
            ok = del_vhost_domains(Vhosts);
        _ ->
            ok
    end.

config_change(Changed, New, Removed) ->
    ok = lists:foreach(fun({K, V}) -> on_config_changed(changed, K, V) end, Changed),
    ok = lists:foreach(fun({K, V}) -> on_config_changed(new,     K, V) end, New),
    ok = lists:foreach(fun(K)      -> on_config_changed(removed, K, []) end, Removed).

%% Called by the release handler (relup) and can be invoked manually from the
%% shell after `application:set_env` to apply non-automatic config changes.
on_config_changed(Action, vhosts, NewVhosts) when Action =:= changed; Action =:= new ->
    OldVhosts = case application:get_env(?APP, vhosts) of
                    {ok, V} -> V;
                    undefined -> []
                end,
    OldDomains = ordsets:from_list([maps:get(domain, V) || V <- OldVhosts]),
    NewDomains  = ordsets:from_list([maps:get(domain, V) || V <- NewVhosts]),
    Added   = ordsets:subtract(NewDomains, OldDomains),
    Removed = ordsets:subtract(OldDomains, NewDomains),
    case cowboy_listen_addr() of
        {_, _, fronting} ->
            [mtp_policy_table:add(personal_domains, tls_domain, list_to_binary(D)) || D <- Added],
            [mtp_policy_table:del(personal_domains, tls_domain, list_to_binary(D)) || D <- Removed];
        _ ->
            ok
    end,
    %% If the primary vhost (default cert) changed, restart the listener
    OldPrimary = case OldVhosts of [H | _] -> H; [] -> undefined end,
    NewPrimary = hd(NewVhosts),
    case OldPrimary =:= NewPrimary of
        true  -> ok;
        false ->
            ?LOG_NOTICE("Primary vhost changed — restarting Cowboy listener to update default cert"),
            restart_listener(NewVhosts)
    end;
on_config_changed(Action, web_listen_ip, _) when Action =:= changed; Action =:= new ->
    ?LOG_NOTICE("web_listen_ip changed — restarting Cowboy listener"),
    restart_listener(read_vhosts());
on_config_changed(Action, web_listen_port, _) when Action =:= changed; Action =:= new ->
    ?LOG_NOTICE("web_listen_port changed — restarting Cowboy listener"),
    restart_listener(read_vhosts());
on_config_changed(_, dets_file, _) ->
    ?LOG_WARNING("dets_file change ignored at runtime — restart the node to apply");
on_config_changed(Action, K, V) ->
    ?LOG_INFO("Config ~p ~p to ~p — no action needed", [K, Action, V]).

%% SNI callback: called by OTP ssl on every TLS handshake.
%% Reads vhosts from application env each time so runtime updates take effect
%% without restarting the listener.
sni_fun(SNI) ->
    case application:get_env(?APP, vhosts) of
        {ok, Vhosts} -> find_vhost_by_sni(SNI, Vhosts);
        undefined    -> []
    end.

%% Private helpers

read_vhosts() ->
    case application:get_env(?APP, vhosts) of
        {ok, Vhosts} when Vhosts =/= [] ->
            Vhosts;
        _ ->
            %% Legacy single-domain config shim
            {ok, Domain}  = application:get_env(?APP, base_domain),
            {ok, SslCert} = application:get_env(?APP, ssl_cert),
            {ok, SslKey}  = application:get_env(?APP, ssl_key),
            ?LOG_WARNING("personal_mtproxy: {base_domain, ssl_cert, ssl_key} config keys are "
                         "deprecated; replace with {vhosts, [#{domain, ssl_cert, ssl_key}]}"),
            [#{domain => Domain, ssl_cert => SslCert, ssl_key => SslKey}]
    end.

find_vhost_by_sni(SNI, Vhosts) ->
    case lists:search(
           fun(#{domain := D}) ->
                   SNI =:= D orelse lists:suffix("." ++ D, SNI)
           end,
           Vhosts)
    of
        {value, #{ssl_cert := Cert, ssl_key := Key}} -> [{certfile, Cert}, {keyfile, Key}];
        false                                         -> []
    end.

add_vhost_domains(Vhosts) ->
    lists:foreach(
      fun(#{domain := D}) ->
              ok = mtp_policy_table:add(personal_domains, tls_domain, list_to_binary(D))
      end, Vhosts).

del_vhost_domains(Vhosts) ->
    lists:foreach(
      fun(#{domain := D}) ->
              ok = mtp_policy_table:del(personal_domains, tls_domain, list_to_binary(D))
      end, Vhosts).

restart_listener(Vhosts) ->
    cowboy:stop_listener(?LISTENER),
    {CowboyIp, CowboyPort, _Kind} = cowboy_listen_addr(),
    #{ssl_cert := DefCert, ssl_key := DefKey} = hd(Vhosts),
    cowboy:start_tls(
      ?LISTENER,
      [{port, CowboyPort}, {ip, CowboyIp},
       {certfile, DefCert}, {keyfile, DefKey},
       {sni_fun, fun ?MODULE:sni_fun/1}],
      #{env => #{dispatch => routes()}}
    ).

%% Validate that IPv4 and IPv6 listeners agree on port and secret
validate_mtproto_ports() ->
    case application:get_env(mtproto_proxy, ports) of
        undefined ->
            {error, no_ports_configured};
        {ok, []} ->
            {error, no_ports_configured};
        {ok, [#{port := Port, secret := Secret} | Rest]} ->
            case lists:all(
              fun(#{port := P, secret := S}) ->
                      P == Port andalso S == Secret
              end,
              Rest)
            of
                true ->
                    ok;
                false ->
                    {error, {mismatched_ports, [#{port => Port, secret => Secret} | Rest]}}
            end;
        _ ->
            {error, invalid_port_config}
    end.

cowboy_listen_addr() ->
    case {application:get_env(?APP, web_listen_ip), application:get_env(?APP, web_listen_port)} of
        {{ok, Ip}, {ok, Port}} ->
            {ok, ParsedIp} = inet:parse_address(Ip),
            {ParsedIp, Port, explicit};
        _ ->
            case application:get_env(mtproto_proxy, domain_fronting) of
                {ok, DomainFronting} ->
                    case string:split(DomainFronting, ":") of
                        [Host, PortStr] ->
                            {ok, Ip} = inet:parse_address(Host),
                            {Ip, list_to_integer(PortStr), fronting};
                        _ ->
                            error({badarg, invalid_domain_fronting_config, DomainFronting})
                    end;
                undefined ->
                    error({missing_web_listen_config,
                           "Set {web_listen_ip, ...} and {web_listen_port, ...} in "
                           "personal_mtproxy config (domain_fronting is not available "
                           "on a back node)"})
            end
    end.

routes() ->
    %% Use '_' (match-all host) rather than per-vhost entries: all vhosts serve
    %% identical routes, and per-vhost dispatch would need to be recompiled on
    %% every runtime vhost change. Host validation for the API is done in
    %% pm_web_handler:validate_vhost/1 instead.
    cowboy_router:compile([
        {'_', [
            {"/api/proxies", pm_web_handler, []},
            {"/", cowboy_static, {priv_file, personal_mtproxy, "htdocs/index.html"}},
            {"/admin.html", pm_admin_redirect_handler, []},
            {"/admin.en.html", cowboy_static, {priv_file, personal_mtproxy, "htdocs/admin.en.html"}},
            {"/admin.ru.html", cowboy_static, {priv_file, personal_mtproxy, "htdocs/admin.ru.html"}},
            {"/static/[...]", cowboy_static, {priv_dir, personal_mtproxy, "htdocs"}}
        ]}
    ]).

start_metrics_listener() ->
    case {application:get_env(?APP, metrics_listen_ip),
          application:get_env(?APP, metrics_listen_port)} of
        {{ok, Ip}, {ok, Port}} ->
            {ok, ParsedIp} = inet:parse_address(Ip),
            Dispatch = cowboy_router:compile([
                {'_', [{"/metrics/[:registry]", prometheus_cowboy2_handler, []}]}
            ]),
            {ok, _} = cowboy:start_clear(
                ?METRICS_LISTENER,
                [{port, Port}, {ip, ParsedIp}],
                #{env => #{dispatch => Dispatch}}
            ),
            ?LOG_INFO("Prometheus metrics on http://~s:~p/metrics", [Ip, Port]),
            ok;
        _ ->
            ok
    end.

stop_metrics_listener() ->
    cowboy:stop_listener(?METRICS_LISTENER).
