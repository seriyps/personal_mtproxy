%%%-------------------------------------------------------------------
%% @doc Cowboy handler for JSON API endpoints
%% POST   /api/proxies                  → register new proxy, return JSON
%% DELETE /api/proxies?subdomain=<sub>  → revoke proxy
%% @end
%%%-------------------------------------------------------------------

-module(pm_web_handler).

-export([init/2]).

-include_lib("kernel/include/logger.hrl").

-define(APP, personal_mtproxy).

init(Req, State) ->
    {Code, Body, Req1} = handle(Req),
    Reply = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Body), Req1),
    {ok, Reply, State}.

handle(Req = #{method := <<"POST">>, path := <<"/api/proxies">>}) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    Params = uri_string:dissect_query(Body),
    Email = proplists:get_value(<<"email">>, Params, <<>>),
    BaseDomain = binary_to_list(cowboy_req:host(Req)),
    case validate_vhost(BaseDomain) of
        false ->
            {400, #{error => <<"unknown vhost">>}, Req1};
        true ->
            case pm_registry:register(Email, BaseDomain) of
                {ok, Subdomain, Port, BaseSecret} ->
                    Secret = iolist_to_binary([<<"ee">>,
                                               string:lowercase(BaseSecret),
                                               string:lowercase(binary:encode_hex(Subdomain))]),
                    Query = uri_string:compose_query([
                      {<<"server">>, Subdomain},
                      {<<"port">>,   integer_to_binary(Port)},
                      {<<"secret">>, Secret}
                    ]),
                    TmeLink = iolist_to_binary(uri_string:recompose(
                      #{scheme => <<"https">>, host => <<"t.me">>, path => <<"/proxy">>, query => Query})),
                    TgLink = iolist_to_binary(uri_string:recompose(
                      #{scheme => <<"tg">>, host => <<"proxy">>, path => <<>>, query => Query})),
                    {200, #{subdomain => Subdomain, link => TmeLink, tg_link => TgLink}, Req1};
                {error, Reason} ->
                    ErrMsg = iolist_to_binary(io_lib:format("~p", [Reason])),
                    {500, #{error => ErrMsg}, Req1}
            end
    end;

handle(Req = #{method := <<"DELETE">>, path := <<"/api/proxies">>}) ->
    Params = cowboy_req:parse_qs(Req),
    case proplists:get_value(<<"subdomain">>, Params) of
        undefined ->
            {400, #{error => <<"missing subdomain parameter">>}, Req};
        Subdomain ->
            case lists:member(Subdomain, pm_registry:get_static_domains()) of
                true ->
                    {403, #{error => <<"cannot revoke a base domain">>}, Req};
                false ->
                    case pm_registry:revoke(Subdomain) of
                        ok ->
                            {200, #{ok => true}, Req};
                        {error, not_found} ->
                            {404, #{error => <<"subdomain not found">>}, Req}
                    end
            end
    end;

handle(Req) ->
    {404, #{error => <<"not found">>}, Req}.

%% Private helpers

validate_vhost(Domain) ->
    case application:get_env(?APP, vhosts) of
        {ok, Vhosts} ->
            lists:any(fun(#{domain := D}) -> D =:= Domain end, Vhosts);
        undefined ->
            false
    end.
