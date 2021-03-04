%% @doc This is the main interface to the library. It provides a function
%% `get_credentials/0' which should return `{ok, Credentials :: map()}' of
%% credentials. If you set `fail_if_unavailable' to `false' in the Erlang
%% environment then the application will return `{ok, unavailable}' and attempt
%% to get credentials again after 5 seconds delay.
%% @end
-module(aws_credentials).
-behaviour(gen_server).

%% As per
%% http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#instance-metadata-security-credentials
%% We make new credentials available at least five minutes prior to the
%% expiration of the old credentials.
-define(ALERT_BEFORE_EXPIRY, 300). % 5 minutes
-define(RETRY_DELAY, 5). % 5 seconds
-define(GREGORIAN_TO_EPOCH_SECONDS, 62167219200).

-include_lib("kernel/include/logger.hrl").

-export([init/1
        ,terminate/2
        ,code_change/3
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,format_status/2
        ]).

-export([start_link/0
        ,stop/0
        ,get_credentials/0
        ,make_map/3
        ,make_map/4
        ,make_map/5
        ]).

-record(state, { credentials = undefined :: map()
                                          | undefined
                                          | information_redacted
               }).
-type state() :: #state{}.

-type credentials() :: #{ credential_provider := aws_credentials_provider:provider()
                        , access_key_id := access_key_id()
                        , secret_access_key := secret_access_key()
                        , token => token()
                        , region => region()
                        }.
-type access_key_id() :: binary().
-type secret_access_key() :: binary().
-type token() :: binary().
-type region() :: binary().

%%====================================================================
%% API
%%====================================================================

-spec make_map(aws_credentials_provider:provider(), access_key_id(), secret_access_key()) ->
        credentials().
make_map(Provider, AccessId, SecretKey) ->
    #{ credential_provider => Provider,
       access_key_id => AccessId,
       secret_access_key => SecretKey
     }.

-spec make_map(aws_credentials_provider:provider(), access_key_id(), secret_access_key(), token()) ->
        credentials().
make_map(Provider, AccessId, SecretKey, Token) ->
    M = make_map(Provider, AccessId, SecretKey),
    maps:put(token, Token, M).

-spec make_map(aws_credentials_provider:provider(), access_key_id(),
               secret_access_key(), token(), region()) ->
        credentials().
make_map(Provider, AccessId, SecretKey, Token, Region) ->
    M = make_map(Provider, AccessId, SecretKey, Token),
    maps:put(region, Region, M).

%% @doc Start the server that stores and automatically updates client
%% credentials fetched from the instance metadata service.
-spec start_link() -> {'ok', pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Stop the server that holds the credentials.
-spec stop() -> 'ok'.
stop() ->
    gen_server:stop(?MODULE).

%% @doc Get the client built with data fetched from the instance metadata
%% service.
-spec get_credentials() -> credentials().
get_credentials() ->
    gen_server:call(?MODULE, get_credentials).

%%====================================================================
%% Behaviour
%%====================================================================

-spec init(_) -> {'ok', state()}.
init(_Args) ->
    {ok, C} = fetch_credentials(),
    {ok, #state{credentials=C}}.

-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    ok.

-spec handle_call(any(), any(), state()) ->
        {'noreply', _} | {'reply', any(), state()}.
handle_call(get_credentials, _From, State=#state{credentials=C}) ->
    {reply, C, State};
handle_call(Args, _From, State) ->
    ?LOG_WARNING("Unknown call: ~p~n", [Args]),
    {noreply, State}.

-spec handle_cast(any(), state()) -> {'noreply', state()}.
handle_cast(Message, State) ->
    ?LOG_WARNING("Unknown cast: ~p~n", [Message]),
    {noreply, State}.

-spec handle_info(any(), state()) -> {'noreply', state()}.
handle_info(refresh_credentials, State) ->
    {ok, C} = fetch_credentials(),
    {noreply, State#state{credentials=C}};
handle_info(Message, State) ->
    ?LOG_WARNING("Unknown message: ~p~n", [Message]),
    {noreply, State}.

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_Prev, State, _Extra) ->
    {ok, State}.

-spec format_status('normal' | 'terminate', any()) -> any().
format_status(_, [_PDict, State]) ->
    [{data, [{"State", State#state{credentials=information_redacted}}]}].

%%====================================================================
%% Internal functions
%%====================================================================

-spec fetch_credentials() -> {ok, credentials() | 'undefined'}.
fetch_credentials() ->
    ShouldCatch = not application:get_env(aws_credentials, fail_if_unavailable, true),
    try
        {ok, Client, ExpirationTime} = aws_credentials_provider:fetch(),
        setup_update_callback(ExpirationTime),
        {ok, Client}
    catch E:R:ST when ShouldCatch ->
            ?LOG_INFO("aws_credentials ignoring exception ~p:~p (~p)~n",
                      [E, R, ST]),
            setup_callback(?RETRY_DELAY),
            {ok, undefined}
    end.

-spec setup_update_callback('infinity' | binary() | integer()) -> ok.
setup_update_callback(infinity) -> ok;
setup_update_callback(Expires) when is_binary(Expires) ->
    RefreshAfter = seconds_until_timestamp(Expires) - ?ALERT_BEFORE_EXPIRY,
    setup_callback(RefreshAfter);
setup_update_callback(Expires) when is_integer(Expires) ->
    setup_callback(Expires - ?ALERT_BEFORE_EXPIRY).

-spec setup_callback(pos_integer()) -> reference().
setup_callback(Seconds) ->
    erlang:send_after(Seconds*1000, self(), refresh_client).

-spec seconds_until_timestamp(binary()) -> integer().
seconds_until_timestamp(Timestamp) ->
    calendar:datetime_to_gregorian_seconds(iso8601:parse(Timestamp))
    - (erlang:system_time(seconds) + ?GREGORIAN_TO_EPOCH_SECONDS).
