-module(maempsia_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
	{ok, MPD}    = application:get_env(maempsia, mpd),
	{ok, Maloja} = application:get_env(maempsia, maloja),
	case maempsia_cli:run(MPD, Maloja) of
	ok             -> init:stop(0), maempsia_sup_dummy:start_link();
	{next, Params} -> maempsia_sup:start_link(Params);
	Other          -> Other
	end.

stop(_State) ->
	ok.
