-module(maempsia_cli).
-export([run/2]).

run(MPD, Maloja) ->
	% TODO MAKE CONDITIONALLY EXECUTABLE
	maempsia_playcounts:run(MPD, Maloja),

	{ok, Radio} = application:get_env(maempsia, radio),
	{ok, PlayListGen} = application:get_env(maempsia, playlist_gen),

	% TODO DEBUG ONLY + INVOKE CORRECTLY
	PL = maempsia_pl_radio:generate(MPD, Radio, maps:get(maempsia_pl_radio, PlayListGen)),
	io:fwrite("PLAYLIST=<~p>~n", [PL]),

	{next, [{mpd, MPD}]}.
