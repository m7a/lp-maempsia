-module(maempsia_cli).
-export([run/2]).

run(MPD, Maloja) ->
	case init:get_argument(help) of
	{ok, _Any} ->
		usage();
	_NoHelpArg ->
		case init:get_argument('sync-playcounts') of
		{ok, _Any} ->
			maempsia_playcounts:run(MPD, Maloja);
		_NoSyncPCNoninteractively ->
			case init:get_argument('import-scrobbles') of
			{ok, [[JSON]]} -> import_scrobbles(Maloja, JSON);
			_RunServer     -> run_server(MPD, Maloja)
			end
		end
	end.

usage() ->
	io:fwrite("~n" ++
"USAGE maempsia [-skip-sync] [-radio [GEN]] -- run regularly~n" ++
"USAGE maempsia -help                       -- this page~n" ++
"USAGE maempsia -sync-playcounts            -- sync playcounts then exit~n" ++
"USAGE maempsia -import-scrobbles JSON      -- import scrobbles from file~n~n"
% TODO x -generate-schedule M3U [GEN] -~> maempsia_radio:schedule_compute...
++
"-skip-sync         Don't synchronize playCount sticker from Maloja on startup"
++ "~n" ++
"-radio GEN         Start radio service with defined algorithm (see config)~n"
++
"-sync-playcounts   Synchronize playCount from Maloja (only)~n" ++
"-import-scrobbles  Import scrobbles from JSON file. Such file is generated if"
++ "~n" ++
"                   `maloja/key` is absent in config. Does not update MPD.~n"
	).

import_scrobbles(Maloja, JSON) ->
	Conn         = {maps:get(url, Maloja), maps:get(key, Maloja)},
	{ok, Binary} = file:read_file(JSON),
	Objects      = binary:split(Binary, <<"\n">>, [global]),
	lists:foreach(fun(ObjectStr) ->
		case ObjectStr /= <<>> of
		true ->
			Map = jiffy:decode(ObjectStr, [return_maps]),
			case maempsia_scrobble:maloja_scrobble(Conn, Map) of
			ok           -> ok;
			ok_exists    -> io:fwrite("already exists: ~s~n",
								[ObjectStr]);
			{error, Msg} -> io:fwrite("~s: ~s~n", [ObjectStr, Msg])
			end;
		false ->
			ok
		end
	end, Objects),
	ok.

run_server(MPD, Maloja) ->
	case init:get_argument('skip-sync') of
	{ok, _Any}                     -> skip;
	_NoSkipSyncBeforeServerStartup -> maempsia_playcounts:run(MPD, Maloja)
	end,
	{next, [{mpd, MPD}, {maloja, Maloja},
		{radio, case init:get_argument('radio') of
				{ok, RadioSetting} -> RadioSetting;
				_NoRadioSetting    -> undefined
			end}]}.
