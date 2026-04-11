%%%-------------------------------------------------------------------
%% @doc Redirect /admin.html to the language-appropriate static page.
%%
%% Parses the Accept-Language header via Cowboy's built-in
%% cow_http_hd:parse_accept_language/1 (quality values are integers
%% 0-1000).  Picks the supported language (ru/en) with the highest
%% quality; defaults to English when nothing matches.
%% @end
%%%-------------------------------------------------------------------

-module(pm_admin_redirect_handler).

-export([init/2]).

init(Req, State) ->
    Location = case preferred_lang(Req) of
                   ru -> <<"/admin.ru.html">>;
                   en -> <<"/admin.en.html">>
               end,
    Reply = cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req),
    {ok, Reply, State}.

preferred_lang(Req) ->
    Langs = cowboy_req:parse_header(<<"accept-language">>, Req, []),
    %% Find the supported language with the highest quality value.
    {_Q, Lang} = lists:foldl(
        fun({Tag, Q}, {BestQ, BestLang}) ->
            case {supported_lang(Tag), Q > BestQ} of
                {none, _}    -> {BestQ, BestLang};
                {L,    true} -> {Q, L};
                {_,    false} -> {BestQ, BestLang}
            end
        end,
        {-1, en},
        Langs),
    Lang.

supported_lang(<<"ru", _/binary>>) -> ru;
supported_lang(<<"en", _/binary>>) -> en;
supported_lang(_)                   -> none.
