-module(maempsia_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).
-define(SERVER, ?MODULE).

start_link(CLIParams) ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, [CLIParams]).

init([CLIParams]) ->
	{ok, Webserver} = application:get_env(maempsia, webserver),
	{ok, {#{strategy => one_for_all, intensity => 0, period => 1}, [
		#{id => maempsia_web, start => {maempsia_web, start,
				[CLIParams ++ maps:to_list(Webserver)]}}
	]}}.
