-module(maempsia_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).
-define(SERVER, ?MODULE).

start_link(CLIParams) ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, [CLIParams]).

init([_CLIParams]) ->
	%{ok, MPD} = application:get_env(maenmpc, mpd),
	{ok, {#{strategy => one_for_all, intensity => 0, period => 1}, [
		#{id => maempsia_web, start => {maempsia_web, start,
					[[{ip, {127,0,0,1}}, {port, 9444}]]}}
	]}}.
