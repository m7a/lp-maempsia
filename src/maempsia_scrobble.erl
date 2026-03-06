-module(maempsia_scrobble).
-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2, maloja_scrobble/2,
	handle_info/2, code_change/3]).
-include_lib("kernel/include/logger.hrl").
% derived from maenmpc_scrobble.erl
-define(EPSILON_SONG, <<>>).
-record(sc, {mpd, maloja, scrobble_file, use_album_art,
						is_active, song, is_complete}).

init([Options]) ->
	Maloja = proplists:get_value(maloja, Options),
	{ok, _TRef} = timer:send_interval(maps:get(interval, Maloja),
							interrupt_check),
	{ok, #sc{
		mpd           = proplists:get_value(mpd, Options),
		maloja        = {maps:get(url, Maloja), maps:get(key, Maloja)},
		scrobble_file = maps:get(scrobble_file, Maloja),
		use_album_art = maps:get(use_album_art, Maloja),
		is_active     = maps:get(scrobble_active, Maloja),
		song          = ?EPSILON_SONG,
		is_complete   = false
	}}.

handle_call(is_active, _From, Ctx = #sc{is_active=Active}) ->
	{reply, Active, Ctx};
handle_call(_Any, _From, Ctx) ->
	{reply, ok, Ctx}.

handle_cast({mpd_idle, Prop}, Ctx = #sc{is_active=true}) ->
	{noreply, mpd_idle(Ctx, Prop, none)};
handle_cast(_Any, Ctx) ->
	{noreply, Ctx}.

mpd_idle(Ctx = #sc{song=CurrentSong, is_complete=IsComplete}, Prop, Conn) ->
	PlayInfo = proplists:get_value(status, Prop, []),
	NewSong = case proplists:get_value(state, PlayInfo) of
		stop   -> ?EPSILON_SONG;
		_Other -> proplists:get_value(file,
			proplists:get_value(currentsong, Prop, []),
			?EPSILON_SONG)
		end,
	case (CurrentSong =/= ?EPSILON_SONG) and (CurrentSong =/= NewSong) and
								IsComplete of
	true                     -> scrobble(Ctx, Conn);
	false when Conn =:= none -> ok;
	false                    -> erlmpd:disconnect(Conn)
	end,
	Ctx#sc{song = NewSong, is_complete = is_complete(PlayInfo)}.

% Per https://www.last.fm/api/scrobbling:
%  - “The track must be longer than 30 seconds.”
%  - “And the track has been played for at least half its duration,
%     or for 4 minutes (whichever occurs earlier.)”
is_complete(PI) ->
	Ela = binary_to_float(proplists:get_value(elapsed,  PI, <<"0.0">>)),
	Dur = binary_to_float(proplists:get_value(duration, PI, <<"1.0">>)),
	Dur >= 30 andalso (Ela >= 240 orelse (Ela * 100.0 / Dur) >= 50.0).

scrobble(Ctx = #sc{mpd=MPD}, none) ->
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	scrobble(Ctx, Conn);
scrobble(Ctx = #sc{song=URI}, Conn) ->
	[Song] = erlmpd:find(Conn, {fileeq, URI}),
	Artist = normalize_key(maempsia_erlmpd:get_artist(Song)),
	Album  = normalize_strong(proplists:get_value('Album', Song, <<>>)),
	Title  = normalize_key(proplists:get_value('Title', Song, <<>>)),
	case (Artist =:= <<>>) or (Album =:= <<>>) or (Title =:= <<>>) of
	true ->
		?LOG_INFO("scrobble skip for incomplete metadata: ~s" ++
				" has ~s/~s/~s", [URI, Artist, Album, Title]),
		erlmpd:disconnect(Conn);
	false ->
		Payload = add_album_art(Ctx, Conn, URI, #{
			artist => Artist,
			album  => Album,
			title  => Title,
			time   => os:system_time(second)
		}),
		?LOG_INFO("scrobble send ~s/~s/~s", [Artist, Album, Title]),
		ok = erlmpd:sticker_inc(Conn, "song", URI, "playCount", 1),
		erlmpd:disconnect(Conn),
		scrobble_send(Ctx, Payload)
	end.

% similar to maempsia_playcounts but without the case fold
normalize_key(V)    -> normalize_always(maempsia_erlmpd:normalize_safe(V)).
normalize_always(V) -> unicode:characters_to_nfc_binary(V).
normalize_strong(V) -> normalize_always(maempsia_erlmpd:normalize_strong(V)).

add_album_art(#sc{use_album_art=false}, _Conn, _URI, Payload) -> Payload;
add_album_art(_Ctx, Conn, URI, Payload) ->
	PIC = erlmpd:readpicture(Conn, URI),
	case PIC of
	{error, Error} ->
		?LOG_ERROR("scrobble failed to read picture for ~s: ~p",
								[URI, Error]),
		Payload;
	{unknown, Binary} ->
		case iolist_size(Binary) of
		0      -> ?LOG_INFO("scrobble no albumart for ~s", [URI]);
		_Other -> ?LOG_WARNING("scrobble unknown image format for ~s",
									[URI])
		end,
		Payload;
	{Type, Binary} ->
		% TODO TO ALIGN WITH MOST RECENT VERSION OF THE PATCH USE `album_image` (or `track_image`)
		maps:put(image, iolist_to_binary([<<"data:">>, Type,
			<<";base64,">>,
			base64:encode(iolist_to_binary(Binary))]), Payload)
	end.

scrobble_send(#sc{maloja=Maloja, scrobble_file=ScrobbleFile}, Payload) ->
	case element(2, Maloja) of
	undefined ->
		% No API key defined, means scrobble should go to file
		scrobble_to_file(ScrobbleFile, Payload);
	_APIKey ->
		case maloja_scrobble(Maloja, Payload) of
		ok             -> ok;
		ok_exists      -> ?LOG_INFO("scrobble exists - not an error");
		{error, Error} ->
			?LOG_ERROR("scrobble to Maloja failed: ~s", [Error]),
			case ScrobbleFile of
			undefined ->
				?LOG_ERROR(
					"scrobble no fallback file - dropped!");
			_File ->
				?LOG_INFO("scrobble fallback to file..."),
				scrobble_to_file(ScrobbleFile, Payload)
			end
		end
	end.

% maenmpc_maloja.erl:scrobble
maloja_scrobble({URL, Key}, Scrobble) ->
	JSON = jiffy:encode(maps:put(key, list_to_binary(Key), Scrobble)),
	Endpoint = binary_to_list(iolist_to_binary(io_lib:format(
					"~s/apis/mlj_1/newscrobble", [URL]))),
	case httpc:request(post, {Endpoint, [], "application/json", JSON},
			[], [{full_result, false}, {body_format, binary}]) of
	{ok, {StatusCode, Body}} ->
		Response = jiffy:decode(Body, [return_maps]),
		case maps:get(<<"status">>, Response) of
		<<"success">> when (StatusCode div 200) == 1 ->
			case maps:get(<<"warnings">>, Response, no_warning) of
			no_warning -> ok;
			[OneWarning] ->
				case maps:get(<<"type">>, OneWarning) of
				<<"scrobble_exists">> -> ok_exists;
				_OtherWarning -> {error, io_lib:format(
					"Unknown warning: ~p", [OneWarning])}
				end;
			MultipleWarnings ->
				{error, io_lib:format("Multiple warnings: ~p",
							[MultipleWarnings])}
			end;
		_Other -> {error, io_lib:format("Status=~w, Response=~s",
							[StatusCode, Body])}
		end;
	{error, Reason} -> {error, io_lib:format("~w", [Reason])}
	end.

scrobble_to_file(F, Payload) ->
	case file:write_file(F, [jiffy:encode(Payload), <<"\n">>], [append]) of
	ok              -> ok;
	{error, Reason} -> ?LOG_ERROR("scrobble failed to write file ~s: ~p",
								[F, Reason])
	end.

handle_info(interrupt_check, Ctx = #sc{is_active=true}) ->
	{noreply, interrupt_check(Ctx)};
handle_info(_Message, Ctx) ->
	{noreply, Ctx}.

interrupt_check(Ctx = #sc{mpd=MPD}) ->
	?LOG_DEBUG("scrobble interrupt_check"),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	Prop = maempsia_erlmpd:get_status_props(Conn),
	mpd_idle(Ctx, Prop, Conn).

code_change(_OldVersion, Ctx, _Extra) -> {ok, Ctx}.
