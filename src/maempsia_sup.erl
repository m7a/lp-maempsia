-module(maempsia_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).
-define(SERVER, ?MODULE).

start_link(CLIParams) ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, [CLIParams]).

init([CLIParams]) ->
	{ok, {#{strategy => one_for_all, intensity => 0, period => 1}, [
		#{id => maempsia_web, start => {maempsia_web, start,
				[CLIParams]}},
		#{id => maempsia_radio, start => {gen_server, start_link,
				[{local, maempsia_radio}, maempsia_radio,
				[CLIParams], []]}},
		#{id => maempsia_idle_listener, start => {gen_server,
				start_link, [{local, maempsia_idle_listener},
				maempsia_idle_listener, [
					proplists:get_value(mpd, CLIParams),
					[maempsia_radio]
				], []]}}
	]}}.
