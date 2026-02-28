-module(maempsia_web).
-author("Linux-Fan, Ma_Sys.ma <info@masysma.net>").
-export([start/1, stop/0]).
-include_lib("kernel/include/logger.hrl").

-define(RATING_UNRATED, -1).
-define(MAX_PL, 1000). % maximum playlist length to load

% ---------------------------------------------------------------[ Templates ]--
-define(XHTML_TPL_TOP,
<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\"
			\"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">
<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en-US\" xml:lang=\"en-US\">
	<head>
		<meta name=\"viewport\"
			content=\"width=device-width, initial-scale=1\"/>
		<title>Ma_Sys.ma Erlang Music Player SideCar Automation</title>
		<style type=\"text/css\">
			/* <![CDATA[ */
			body { font-family: \"PT Mono\", monospace }
			/* ]]> */
		</style>
	</head>
	<body>
		<h1>Ma_Sys.ma Erlang Music Player SideCar Automation</h1>
">>).
-define(XHTML_TPL_BOT, <<"
	</body>
</html>
">>).
-define(XHTML_PLAYLIST_BOT, <<"\t\t\t</tbody>\n\t\t</table>">>).

% --------------------------------------------------------------------[ Code ]--
start(Options) ->
	MPD = proplists:get_value(mpd, Options),
	{ok, RadioGenerators} = application:get_env(maempsia, playlist_gen),
	{ok, ServerOptionsRaw} = application:get_env(maempsia, webserver),
	RadioOptions = lists:sort(maps:keys(RadioGenerators)),
	% TODO THERE IS ALSO A start_link version which I should probably prefer?
	mochiweb_http:start([{name, ?MODULE}|[ {loop, fun(Req) ->
						loop(MPD, RadioOptions, Req)
					end}|maps:to_list(ServerOptionsRaw)]]).

stop() ->
	mochiweb_http:stop(?MODULE).

loop(MPD, RadioOptions, Req) ->
	Method = mochiweb_request:get(method, Req),
	case mochiweb_request:get(path, Req) of
	% start
	"/" when Method =:= 'GET'; Method =:= 'HEAD' ->
		redirect("index.xhtml", Req);
	% pages
	"/index.xhtml" when Method =:= 'GET'; Method =:= 'HEAD' ->
		respond_tab_start(MPD, RadioOptions, Req);
	"/playlist.xhtml" when Method =:= 'GET'; Method =:= 'HEAD' ->
		respond_tab_playlist(MPD, Req);
	"/songs.xhtml" when Method =:= 'GET'; Method =:= 'POST' ->
		respond_tab_songs(MPD, Req);
	% control
	"/add_album.erl" when Method =:= 'POST' ->
		process_add_album(MPD, Req);
	"/add_song_from_songs.erl" when Method =:= 'POST' ->
		process_add_song(MPD, Req, "songs.xhtml");
	"/add_song_from_playlist.erl" when Method =:= 'POST' ->
		process_add_song(MPD, Req, "playlist.xhtml");
	"/add_song_from_start.erl" when Method =:= 'POST' ->
		process_add_song(MPD, Req, "index.xhtml");
	"/modify_service.erl" when Method =:= 'POST' ->
		process_modify_service(RadioOptions, Req);
	_Other ->
		mochiweb_request:respond({404, [{"Content-Type", "text/plain"}],
					"not found\n"}, Req)
	end.

redirect(Target, Req) ->
	mochiweb_request:respond({302, [{"Location", Target}], ""}, Req).

respond_tab_start(MPD, RadioOptions, Req) ->
	{Gen, Schedule} = gen_server:call(maempsia_radio, get_schedule),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	Status  = erlmpd:status(Conn),
	CurID   = proplists:get_value(songid, Status, -1),
	CurPOS  = max(1, proplists:get_value(song, Status, 1)),
	CurSong = erlmpd:currentsong(Conn),
	PLength = proplists:get_value(playlistlength, Status, 0),
	PLRows  = [generate_playlist_row(Conn, CurID, Song) || Song <-
			erlmpd:playlistinfo(Conn, {CurPOS - 1, PLength})],
	ScheduleInfo = [generate_schedule_row(Conn, URI) || URI <- Schedule],
	erlmpd:disconnect(Conn),

	RadioFormOpt = generate_radio_options(['---'|RadioOptions],
							Gen, Schedule =/= []),
	SongInfo = [format_artist(CurSong), <<", ">>, format_date(CurSong),
					<<": ">>, format_title(CurSong)],
	VolumeInfo = case proplists:get_value(volume, Status) of
			undefined -> <<"?">>;
			-1        -> <<"?">>;
			PercVal   -> [integer_to_binary(PercVal), <<"%">>]
		end,
	TimeInfo = [format_duration_time(floor(proplists:get_value(time, Status,
			0))), <<"|">>, format_duration_time(ceil(binary_to_float
			(proplists:get_value(duration, Status, <<"0.0">>))))],
	respond_with_page([
		<<"\t\t<form method=\"post\" action=\"modify_service.erl\">
			<table>
			<tr>
				<td><label for=\"radio_generator\">Radio
								</label></td>
				<td>
					<select name=\"radio_generator\">\n">>,
		RadioFormOpt,
		<<"\t\t\t\t\t</select>
				</td>
				<td><input type=\"submit\" name=\"radio\"
							value=\"Set\"/></td>
			</tr>
			</table>
			</form>\n">>,
		generate_xhtml_playlist_top(<<"Action">>),
		PLRows,
		?XHTML_PLAYLIST_BOT,
		<<"\t\t<table border=\"1\">
			<tr>
				<td rowspan=\"2\">Play/Pause</td>
				<td>">>, SongInfo, <<"</td>
				<td rowspan=\"2\">Vol-</td>
				<td rowspan=\"2\">">>, VolumeInfo, <<"</td>
				<td rowspan=\"2\">Vol+</td>
			</tr>
			<tr><td>">>, TimeInfo, <<"</td></tr>\n\t\t</table>\n">>,
		generate_xhtml_playlist_top(<<"PC">>),
		ScheduleInfo,
		?XHTML_PLAYLIST_BOT
	], <<"index.xhtml">>, Req).

generate_playlist_row(Conn, Curs, Song) ->
	URI = proplists:get_value(file, Song),
	ID  = proplists:get_value('Id', Song),
	{BO, BC} = case ID =:= Curs of
			true  -> {<<"<strong>">>, <<"</strong>">>};
			false -> {<<>>, <<>>}
		end,
	[<<"\t\t\t\t<tr>">>,
	format_add_song_td(URI, <<"add_song_from_playlist.erl">>),
	<<"<td>">>,      BO, format_rating(
				maempsia_erlmpd:get_rating(Conn, URI)), BC,
	<<"</td><td>">>, BO, format_artist(Song),                       BC,
	<<"</td><td>">>, BO, format_title(Song),                        BC,
	<<"</td><td>">>, BO, format_duration(Song),                     BC,
	<<"</td><td><form method=\"post\" action=\"modify_playlist.erl\">
	\t\t\t\t<input type=\"hidden\" name=\"id\" value=\"">>,
						integer_to_binary(ID), <<"\"/>
	\t\t\t\t<input type=\"submit\" name=\"act_remove\" value=\"-\"/>
	\t\t\t\t<input type=\"submit\" name=\"act_play\" value=\"&#9205;\"/>
	\t\t\t</form></td></tr>\n">>].

generate_schedule_row(Conn, URI) ->
	[Song] = erlmpd:find(Conn, {fileeq, URI}),
	[<<"\t\t\t\t<tr>">>,
	format_add_song_td(URI, <<"add_song_from_start.erl">>),
	<<"<td>">>,      format_rating(maempsia_erlmpd:get_rating(Conn, URI)),
	<<"</td><td>">>, format_artist(Song),
	<<"</td><td>">>, format_title(Song),
	<<"</td><td>">>, format_duration(Song),
	<<"</td><td>">>,
	integer_to_binary(maempsia_erlmpd:get_playcount(Conn, URI)),
	"</td></tr>\n"].

respond_with_page(Text, OnPage, Req) ->
	mochiweb_request:respond({200, [
		{"Content-Type", "application/xhtml+xml; charset=UTF-8"}
	], [
		?XHTML_TPL_TOP, generate_navigation(OnPage), Text,
		?XHTML_TPL_BOT
	]}, Req).

generate_navigation(OnPage) ->
	[<<"\t\t<p id=\"navigation\">| ">>, [case Page of
		{Title1, OnPage} ->
			[Title1, <<" | ">>];
		{Title2, Link} ->
			[<<"<a href=\"">>, Link, <<"\">">>, Title2, <<"</a> | ">>]
		end
	|| Page <- [
		{<<"Start">>,    <<"index.xhtml">>},
		{<<"Playlist">>, <<"playlist.xhtml">>},
		{<<"Songs">>,    <<"songs.xhtml">>}
	]], <<"</p>\n">>].

generate_radio_options(RadioOptions, Gen, HasSchedule) ->
	lists:map(fun(Ent) ->
		Esc    = quote_xml(atom_to_binary(Ent)),
		Suffix = [Esc, <<"</option>\n">>],
		Prefix = [<<"\t\t\t\t\t\t<option value=\"">>, Esc, <<"\"">>],
		case Ent of
		Gen when HasSchedule ->
			[Prefix|[<<" selected=\"selected\">">>|Suffix]];
		_Other ->
			[Prefix|[<<">">>|Suffix]]
		end
	end, RadioOptions).

generate_xhtml_playlist_top(LastCol) ->
	[<<"\t\t<table border=\"1\">
			<thead><tr>
				<th>Action</th>
				<th>Rated</th>
				<th>Artist</th>
				<th>Title</th>
				<th>MM:ss</th>
				<th>">>, LastCol, <<"</th>
			</tr></thead>
			<tbody>\n">>].

respond_tab_playlist(MPD, Req) ->
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	ok = erlmpd:tagtypes_clear(Conn),
	ok = erlmpd:tagtypes_enable(Conn, [artist, album, title, albumartist]),
	Status  = erlmpd:status(Conn),
	PLength = proplists:get_value(playlistlength, Status, 0),
	Curs    = proplists:get_value(songid, Status, -1),
	Rows = case PLength > ?MAX_PL of
		true -> [[<<"\t\t\t\t<tr><td>...</td><td>...</td>">>,
					<<"<td colspan=\"2\"><em>Skipped ">>,
					integer_to_binary(PLength - 600),
					<<" playlist entries.</em></td>">>,
					<<"<td>...</td><td>...</td></tr>\n">>]
				|[generate_playlist_row(Conn, Curs, Song)
					|| Song <- erlmpd:playlistinfo(Conn,
					{PLength - ?MAX_PL + 1, PLength})]];
		false -> [generate_playlist_row(Conn, Curs, Song) ||
					Song <- erlmpd:playlistinfo(Conn)]
		end,
	erlmpd:disconnect(Conn),
	respond_with_page([generate_xhtml_playlist_top(<<"Action">>), Rows,
			?XHTML_PLAYLIST_BOT], <<"playlist.xhtml">>, Req).

respond_tab_songs(MPD, Req) ->
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	% This tag type limiting brings a massive performance improvement
	ok = erlmpd:tagtypes_clear(Conn),
	ok = erlmpd:tagtypes_enable(Conn,
			[track, artist, album, date, title, albumartist, disc]),
	Rows = [generate_songs_rows(Conn, Artist) ||
		Artist <- erlmpd:list(Conn, albumartist), Artist /= <<>>],
	erlmpd:disconnect(Conn),
	respond_with_page([<<"\t\t<table border=\"1\">\n
			<thead><tr>
				<th>Action</th>
				<th>Rated</th>
				<th>No.</th>
				<th>Title</th>
				<th>Duration</th>
			</tr></thead>
			<tbody>\n">>,
				Rows,
			<<"\t\t\t</tbody>\n\t\t</table>\n">>],
		<<"songs.xhtml">>, Req).

generate_songs_rows(Conn, Artist) ->
	{_Meta, Val} = lists:foldl(fun(Song, MetaAcc) ->
			accumulate_row(Conn, Song, MetaAcc)
		end, {{}, []}, sort_songs(erlmpd:find(Conn,
			{tagop, albumartist, eq, Artist}
		))),
	Val.

accumulate_row(Conn, Song, {Meta, Acc}) ->
	SMeta = {proplists:get_value('Album', Song),
					proplists:get_value('Disc', Song, -1)},
	{SMeta, [Acc|case SMeta =:= Meta of
		true  -> format_song(Conn, Song);
		false -> [format_header(Song)|format_song(Conn, Song)]
	end]}.

format_header(Song) ->
	ArtistQuot = format_artist(Song),
	AlbumQuot = quote_xml(proplists:get_value('Album', Song,
							<<"(unknown album)">>)),
	Disc = proplists:get_value('Disc', Song, -1),
	DiscInfo = case Disc of
			-1    -> <<>>;
			1     -> <<>>;
			_Disc -> [<<" (">>, integer_to_binary(Disc), <<")">>]
		end,
	[<<"\t\t\t\t<tr><th colspan=\"4\">">>, ArtistQuot,
	<<" (">>, format_date(Song),
	<<"): ">>, AlbumQuot, DiscInfo, <<"</th><td>
	\t\t\t\t<form method=\"post\" action=\"add_album.erl\">
	\t\t\t\t\t<input type=\"hidden\" name=\"artist\" value=\"">>,
					ArtistQuot, <<"\"/>
	\t\t\t\t\t<input type=\"hidden\" name=\"album\" value=\"">>,
					AlbumQuot, <<"\"/>
	\t\t\t\t\t<input type=\"hidden\" name=\"disc\" value=\"">>,
					integer_to_binary(Disc), <<"\"/>
	\t\t\t\t\t<input type=\"submit\" name=\"add_here\" value=\"A\"/>
	\t\t\t\t\t<input type=\"submit\" name=\"add_end\" value=\"a\"/>
	\t\t\t\t</form>
	\t\t\t</td></tr>\n">>].

format_artist(Song) ->
	quote_xml(proplists:get_value('AlbumArtist', Song,
		proplists:get_value('Artist', Song, <<"(unknown artist)">>))).

format_date(Song) ->
	quote_xml(proplists:get_value('Date', Song, <<"?">>)).

% https://stackoverflow.com/questions/3339014/how-do-i-xml-encode-a-string-in
quote_xml(Str) -> lists:map(fun quote_xml_char/1,
				lists:flatten(io_lib:format("~s", [Str]))).
quote_xml_char($<) -> <<"&lt;">>;
quote_xml_char($>) -> <<"&gt;">>;
quote_xml_char($&) -> <<"&amp;">>;
quote_xml_char($") -> <<"&quot;">>;
quote_xml_char($') -> <<"&apos;">>;
quote_xml_char(C)  -> C.

format_song(Conn, Song) ->
	URI = proplists:get_value(file, Song),
	[<<"\t\t\t\t<tr>">>,
	format_add_song_td(URI, <<"add_song_from_songs.erl">>),
	<<"<td>">>, format_rating(maempsia_erlmpd:get_rating(Conn, URI)),
	<<"</td><td>">>,
	integer_to_binary(proplists:get_value('Track', Song, 0)),
	<<"</td><td>">>, format_title(Song),
	<<"</td><td>">>, format_duration(Song), <<"</td></tr>\n">>].

format_title(Song) ->
	quote_xml(proplists:get_value('Title', Song, <<"(untitled)">>)).

format_add_song_td(URI, Action) ->
	[<<"<td>
	\t\t\t\t<form method=\"post\" action=\"">>, Action, <<"\">
	\t\t\t\t\t<input type=\"hidden\" name=\"file\" value=\"">>,
							quote_xml(URI), <<"\"/>
	\t\t\t\t\t<input type=\"submit\" name=\"add_end\" value=\"a\"/>
	\t\t\t\t\t<input type=\"submit\" name=\"add_here\" value=\"A\"/>
	\t\t\t\t</form>
	\t\t\t</td>">>].

format_rating(?RATING_UNRATED) -> <<"- - -">>;
format_rating(10)              -> <<"&#9733;&#9733;&#9733;&#9733;&#9733;">>;
format_rating( 9)              -> <<"&#9733;&#9733;&#9733;&#9733;&#9734;">>;
format_rating( 8)              -> <<"&#9733;&#9733;&#9733;&#9733;.">>;
format_rating( 7)              -> <<"&#9733;&#9733;&#9733;&#9734;.">>;
format_rating( 6)              -> <<"&#9733;&#9733;&#9733;..">>;
format_rating( 5)              -> <<"&#9733;&#9733;&#9734;..">>;
format_rating( 4)              -> <<"&#9733;&#9733;...">>;
format_rating( 3)              -> <<"&#9733;&#9734;...">>;
format_rating( 2)              -> <<"&#9733;....">>;
format_rating( 1)              -> <<"&#9734;....">>;
format_rating( 0)              -> <<".....">>;
format_rating(_Other)          -> <<"!ERR!">>.

format_duration(Song) ->
	format_duration_time(max(1, proplists:get_value('Time', Song, 1))).

format_duration_time(Duration) ->
	list_to_binary(io_lib:format("~2..0w:~2..0w",
					[Duration div 60, Duration rem 60])).

sort_songs(Songs) ->
	lists:sort(fun(SA, SB) ->
		cmp_prop_lex(SA, SB, ['Date', 'Album', 'Disc', 'Track'])
	end, Songs).

cmp_prop_lex(_ListA, _ListB, []) ->
	true;
cmp_prop_lex(ListA, ListB, [Tag|Rem]) ->
	ValA = proplists:get_value(Tag, ListA),
	ValB = proplists:get_value(Tag, ListB),
	if
	ValA =:= ValB -> cmp_prop_lex(ListA, ListB, Rem);
	ValA =< ValB  -> true;
	true          -> false
	end.

process_add_album(MPD, Req) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	% TODO x SECURITY FORM VALUE DIRECTLY TO MPD - VALIDATE BEFORE!
	DiscFlt = case proplists:get_value("disc", Form, "-1") of
			"-1" -> [];
			Disc -> [{tagop, disc, eq, Disc}]
		end,

	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	SongsURIs = [proplists:get_value(file, Song)
		|| Song <- sort_songs(erlmpd:find(Conn, {land, DiscFlt ++ [
			{tagop, album, eq, proplists:get_value("album", Form)},
			{tagop, albumartist, eq, proplists:get_value("artist",
									Form)}
		]}))],

	case is_add_here(Form) of
	true ->
		% maenmpc_singleplayer.erl:enqueue_after_current
		PLength = proplists:get_value(playlistlength,
							erlmpd:status(Conn), 0),
		lists:foreach(fun({URI, Offset}) ->
			case erlmpd:addid_relative(Conn, URI, Offset) of
			{error, {mpd_error, "55", _EPos, "addid", _NoCurSon}} ->
				% Special case no current song need to insert
				% using absolute offset...
				erlmpd:addid(Conn, URI, PLength + Offset);
			IDOK ->
				IDOK
			end
		end, lists:zip(SongsURIs, lists:seq(0, length(SongsURIs) - 1)));
	false ->
		lists:foreach(fun(URI) ->
			ok = erlmpd:add(Conn, URI)
		end, SongsURIs)
	end,
	erlmpd:disconnect(Conn),
	redirect("songs.xhtml", Req).

% add_end/a, add_here/A - query for add_end and if it is absent assume add_here.
% This logic is as good as any and it does not seem to be worth checking for
% consistency here.
is_add_here(Form) ->
	proplists:get_value("add_end", Form, add_here) =:= add_here.

process_add_song(MPD, Req, ReturnTo) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	% TODO x SECURITY - VALIDATE URI BEFORE PASSING TO API HERE
	URI = proplists:get_value("file", Form),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	case is_add_here(Form) of
	true ->
		case erlmpd:addid_relative(Conn, URI, 0) of
		{error, {mpd_error, "55", _EPos, "addid", _NoCurSon}} ->
			erlmpd:addid(Conn, URI, proplists:get_value(
				playlistlength, erlmpd:status(Conn), 0));
		IDOK ->
			IDOK
		end;
	false ->
		ok = erlmpd:add(Conn, URI)
	end,
	erlmpd:disconnect(Conn),
	redirect(ReturnTo, Req).

process_modify_service(RadioOptions, Req) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	% TODO x security maybe its better to convert RadioOptions to list of lists and then do membership request in favor of list_to_atom
	GenToSet = list_to_atom(proplists:get_value("radio_generator", Form,
									"---")),
	case lists:member(GenToSet, RadioOptions) of
	true ->
		ok = gen_server:cast(maempsia_radio, {radio_start, GenToSet});
	false when GenToSet =:= '---' ->
		ok = gen_server:cast(maempsia_radio, radio_stop);
	_Any ->
		?LOG_WARNING("invalid form for radio_generator field")
	end,
	redirect("index.xhtml", Req).
