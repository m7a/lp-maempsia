-module(maempsia_cli).
-export([run/2]).

run(MPD, _Maloja) ->
	{next, [{mpd, MPD}]}.
