-module(maempsia_cli).
-export([run/2]).

run(MPD, Maloja) ->
	% TODO MAKE CONDITIONALLY EXECUTABLE
	maempsia_playcounts:run(MPD, Maloja),
	{next, [{mpd, MPD}]}.
