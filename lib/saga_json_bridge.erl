-module(saga_json_bridge).
-export([parse_string/1, to_list/1, is_null/1]).

%% Parse a JSON binary into an Erlang term using OTP's built-in json module.
parse_string(S) when is_binary(S) ->
    try
        {ok, json:decode(S)}
    catch
        error:Reason ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;
parse_string(_) ->
    {error, <<"parse_string requires a binary">>}.

%% Extract the inner list from a JSON array Dynamic.
to_list(L) when is_list(L) -> {ok, L};
to_list(V) ->
    {error, {std_dynamic_DecodeError, <<"List">>, std_dynamic_bridge:classify(V), []}}.

%% Check whether a Dynamic is the JSON null value.
is_null(null) -> true;
is_null(_) -> false.
