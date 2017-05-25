%%%-------------------------------------------------------------------
%% @doc navstar top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(navstar_overlay_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).


%% API
-export([]).
%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link([Enabled]) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Enabled]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

get_children(false) ->
    [];
get_children(true) ->
    [
        ?CHILD(navstar_overlay_poller, worker),
        ?CHILD(navstar_overlay_lashup_kv_listener, worker)
    ].

init([Enabled]) ->
    {ok, {{rest_for_one, 5, 10}, get_children(Enabled)}}.
