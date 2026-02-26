-module(maempsia_erlmpd).
-export([connect/1]).
-include_lib("kernel/include/logger.hrl").

connect(MPD) ->
	{Host, Port} = maps:get(ip, MPD),
	case erlmpd:connect(Host, Port) of
	{ok, Conn} ->
		{ok, Conn};
	Error ->
		?LOG_ERROR("Failed to connect to ~p: ~p", [MPD, Error]),
		Error
	end.
