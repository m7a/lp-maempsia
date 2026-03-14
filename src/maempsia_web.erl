-module(maempsia_web).
-author("Linux-Fan, Ma_Sys.ma <info@masysma.net>").
-export([start/1, stop/0]).
-include_lib("kernel/include/logger.hrl").

-define(RATING_UNRATED, -1).
-define(RATING_NOTPOSS, -2).
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
		<meta name=\"color-scheme\" content=\"light dark\"/>
		<title>Ma_Sys.ma Erlang Music Player SIdecar Automation</title>
		<style type=\"text/css\">
			/* <![CDATA[ */
			body {
				font-family: \"PT Mono\", monospace;
			}
			.arathigh {
				color: AccentColorText;
				background-color: AccentColor;
			}
			.aratmax {
				color: MarkText;
				background-color: Mark;
			}
			/* ]]> */
		</style>
	</head>
	<body>
		<h1>Ma_Sys.ma Erlang Music Player SIdecar Automation</h1>
">>).
-define(XHTML_TPL_BOT, <<"
	</body>
</html>
">>).
-define(XHTML_PLAYLIST_BOT, <<"\t\t\t</tbody>\n\t\t</table>">>).
-define(XHTML_SONGS_TBL_BEGIN, <<"
		<table border=\"1\">
			<thead><tr>
				<th>Action</th>
				<th>Rated</th>
				<th>No.</th>
				<th>Title</th>
				<th>Duration</th>
			</tr></thead>
			<tbody>
">>).
-define(XHTML_SONGS_TBL_END, <<"\t\t\t</tbody>\n\t\t</table>\n">>).

% --------------------------------------------------------------------[ Code ]--
start(Options) ->
	MPD = proplists:get_value(mpd, Options),
	{ok, RadioGenerators}     = application:get_env(maempsia, playlist_gen),
	{ok, ServerOptionsRaw}    = application:get_env(maempsia, webserver),
	{ok, WebinterfaceOptions} = application:get_env(maempsia, webinterface),
	RadioOptions = lists:sort(maps:keys(RadioGenerators)),
	Files        = lists:sort(maps:get(files, WebinterfaceOptions)),
	% TODO THERE IS ALSO A start_link version which I should probably prefer?
	mochiweb_http:start([{name, ?MODULE}|[ {loop, fun(Req) ->
					loop(MPD, RadioOptions, Files, Req)
				end}|maps:to_list(ServerOptionsRaw)]]).

stop() ->
	mochiweb_http:stop(?MODULE).

loop(MPD, RadioOptions, Files, Req) ->
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
	"/songs.xhtml" when Method =:= 'GET'; Method =:= 'HEAD' ->
		respond_tab_songs(MPD, Req);
	"/albums.xhtml" when Method =:= 'GET'; Method =:= 'HEAD' ->
		respond_tab_albums(MPD, Req);
	"/files.xhtml" when Method =:= 'GET' ->
		respond_tab_files(Files, Req);
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
	"/modify_playlist_from_start.erl" when Method =:= 'POST' ->
		process_modify_playlist(MPD, Req, "index.xhtml");
	"/modify_playlist_from_playlist.erl" when Method =:= 'POST' ->
		process_modify_playlist(MPD, Req, "playlist.xhtml");
	"/control_player.erl" when Method =:= 'POST' ->
		process_control_player(MPD, Req);
	"/rate_up.erl" when Method =:= 'POST' ->
		process_update_rating(MPD, Req, 2);
	"/rate_down.erl" when Method =:= 'POST' ->
		process_update_rating(MPD, Req, -2);
	_Other ->
		mochiweb_request:respond({404, [{"Content-Type", "text/plain"}],
					"not found\n"}, Req)
	end.

redirect(Target, Req) ->
	mochiweb_request:respond({302, [{"Location", Target}], ""}, Req).

respond_tab_start(MPD, RadioOptions, Req) ->
	{Gen, Sched} = gen_server:call(maempsia_radio, get_schedule),
	HasPodcast   = gen_server:call(maempsia_podcast, is_active),
	IsScrobbling = gen_server:call(maempsia_scrobble, is_active),
	{ok, Conn}   = maempsia_erlmpd:connect(MPD),
	Status       = erlmpd:status(Conn),
	CurID        = proplists:get_value(songid, Status, -1),
	CurSong      = erlmpd:currentsong(Conn),
	PLength      = proplists:get_value(playlistlength, Status, 0),
	CurPOS       = max(1, proplists:get_value(song, Status, PLength - 10)),
	PLRows       = [generate_playlist_row(Conn, CurID, Song, <<"start">>)
					|| Song <- erlmpd:playlistinfo(Conn,
					{CurPOS - 1, PLength})],
	ScheduleInfo = [generate_schedule_row(Conn, URI) || URI <- Sched],
	erlmpd:disconnect(Conn),

	RadioFormOpt = generate_radio_options(['---'|RadioOptions], Gen,
								Sched =/= []),
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
			<tr>\n">>,
				generate_podcast_form_cell(HasPodcast,
						"podcast_stop", "Stop"),
				<<"<td>Podcast</td>\n">>,
				generate_podcast_form_cell(not HasPodcast,
						"podcast_start", "Start"),
			<<"\t\t\t\t\t</tr>
			<tr><td rowspan=\"3\">scrobbling: ">>,
			case IsScrobbling of
			true  -> <<"active">>;
			false -> <<"disabled">>
			end,
			<<"</td></tr>
			</table>
			</form>\n">>,
		generate_xhtml_playlist_top(<<"Action">>),
		PLRows,
		?XHTML_PLAYLIST_BOT,
		<<"\t\t<form method=\"post\" action=\"control_player.erl\">
			<table border=\"1\">
			<tr>
				<td rowspan=\"2\"><input type=\"submit\"
					name=\"toggle_play_pause\"
					value=\"Play/Pause\"/></td>
				<td>">>, SongInfo, <<"</td>
				<td rowspan=\"2\"><input type=\"submit\"
					name=\"volume_down\"
					value=\"Vol-\"/></td>
				<td rowspan=\"2\">">>, VolumeInfo, <<"</td>
				<td rowspan=\"2\"><input type=\"submit\"
					name=\"volume_up\"
					value=\"Vol+\"/></td>
			</tr>
			<tr><td>">>, TimeInfo, <<"</td></tr>\n\t\t</table>
			</form>\n">>,
		generate_xhtml_playlist_top(<<"PC">>),
		ScheduleInfo,
		?XHTML_PLAYLIST_BOT
	], <<"index.xhtml">>, Req).

generate_playlist_row(Conn, Curs, Song, From) ->
	URI = proplists:get_value(file, Song),
	ID  = proplists:get_value('Id', Song),
	{BO, BC} = case ID =:= Curs of
			true  -> {<<"<strong>">>, <<"</strong>">>};
			false -> {<<>>, <<>>}
		end,
	[<<"\t\t\t\t<tr>">>,
	format_add_song_td(URI, [<<"add_song_from_">>, From, <<".erl">>]),
	<<"<td>">>,      BO, format_rating(
				maempsia_erlmpd:get_rating(Conn, URI)), BC,
	<<"</td><td>">>, BO, format_artist(Song),                       BC,
	<<"</td><td>">>, BO, format_title(Song),                        BC,
	<<"</td><td>">>, BO, format_duration(Song),                     BC,
	<<"</td><td><form method=\"post\" action=\"modify_playlist_from_">>,
							From, <<".erl\">
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

generate_podcast_form_cell(Enable, _Name, _Label) when not Enable ->
	<<"\t\t\t\t\t\t<td></td>\n">>;
generate_podcast_form_cell(_Enable, Name, Label) ->
	[<<"\t\t\t\t\t\t<td><input type=\"submit\" name=\"">>, Name,
				<<"\" value=\"">>, Label, <<"\"/></td>\n">>].

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
		{<<"Albums">>,   <<"albums.xhtml">>},
		{<<"Songs">>,    <<"songs.xhtml">>},
		{<<"Files">>,    <<"files.xhtml">>}
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
				|[generate_playlist_row(Conn, Curs, Song,
					<<"playlist">>)
					|| Song <- erlmpd:playlistinfo(Conn,
					{PLength - ?MAX_PL + 1, PLength})]];
		false -> [generate_playlist_row(Conn, Curs, Song,
								<<"playlist">>)
					|| Song <- erlmpd:playlistinfo(Conn)]
		end,
	erlmpd:disconnect(Conn),
	respond_with_page([generate_xhtml_playlist_top(<<"Action">>), Rows,
			?XHTML_PLAYLIST_BOT], <<"playlist.xhtml">>, Req).

respond_tab_songs(MPD, Req) ->
	respond_tab_songs_cb(MPD, Req, fun accumulate_row/4, <<"songs.xhtml">>).

respond_tab_songs_cb(MPD, Req, CB, Return) ->
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	% This tag type limiting brings a massive performance improvement
	ok = erlmpd:tagtypes_clear(Conn),
	ok = erlmpd:tagtypes_enable(Conn,
			[track, artist, album, date, title, albumartist, disc]),
	Rows = [generate_songs_rows(Conn, Artist, Return, CB) ||
		Artist <- erlmpd:list(Conn, albumartist), Artist /= <<>>],
	erlmpd:disconnect(Conn),
	respond_with_page([?XHTML_SONGS_TBL_BEGIN, Rows,
					?XHTML_SONGS_TBL_END], Return, Req).

generate_songs_rows(Conn, Artist, Return, CB) ->
	{_Meta, Val} = lists:foldl(fun(Song, MetaAcc) ->
		CB(Conn, Song, Return, MetaAcc)
	end, {{}, []}, sort_songs(erlmpd:find(Conn,
		{tagop, albumartist, eq, Artist}
	))),
	lists:reverse(Val).

accumulate_row(Conn, Song, Return, {Meta, Acc}) ->
	SMeta = {proplists:get_value('Album', Song),
					proplists:get_value('Disc', Song, -1)},
	{SMeta, case SMeta =:= Meta of
		true  -> [format_song(Conn, Song)|Acc];
		false -> [format_song(Conn, Song)|[format_header(Conn, Song,
							Return, <<"th">>)|Acc]]
		end}.

format_header(Conn, Song, Return, AlbumTag) ->
	Artist     = format_artist_noquot(Song),
	ArtistQuot = quote_xml(Artist),
	Album      = proplists:get_value('Album', Song, <<"(unknown album)">>),
	AlbumQuot  = quote_xml(Album),
	Anchor     = ["hdr_", normalize_for_id(Artist), $_,
						normalize_for_id(Album)],
	Disc       = proplists:get_value('Disc', Song, -1),
	DiscInfo   = case Disc of
			-1    -> <<>>;
			1     -> <<>>;
			_Disc -> [<<" (">>, integer_to_binary(Disc), <<")">>]
			end,
	InputForAlbum = [<<"
		\t\t\t\t\t<input type=\"hidden\" name=\"return\" value=\"">>,
						Return, <<"\"/>
		\t\t\t\t\t<input type=\"hidden\" name=\"artist\" value=\"">>,
						ArtistQuot, <<"\"/>
		\t\t\t\t\t<input type=\"hidden\" name=\"album\" value=\"">>,
						AlbumQuot, <<"\"/>">>],
	AlbumRating = maempsia_erlmpd:get_album_rating(Conn, Song),
	{RatingEnabled, RatingClass} = if
		AlbumRating =:= ?RATING_NOTPOSS
				-> {<<" disabled=\"disabled\"">>, <<>>};
		AlbumRating > 8 -> {<<>>, <<" class=\"aratmax\"">>};
		AlbumRating > 6 -> {<<>>, <<" class=\"arathigh\"">>};
		true            -> {<<>>, <<>>}
		end,
	[<<"\t\t\t\t<tr>
	\t\t\t\t<td>
	\t\t\t\t\t<a id=\"">>, Anchor, <<"\"/>
	\t\t\t\t\t<form method=\"post\" action=\"rate_down.erl\">">>,
							InputForAlbum, <<"
	\t\t\t\t\t\t<input type=\"submit\" name=\"rminus\" value=\"R-\"">>,
							RatingEnabled, <<"/>
	\t\t\t\t\t</form>
	\t\t\t\t</td>
	\t\t\t\t<td">>, RatingClass, <<">">>, format_rating(AlbumRating),
								<<"</td>
	\t\t\t\t<td>
	\t\t\t\t\t<form method=\"post\" action=\"rate_up.erl\">">>,
							InputForAlbum, <<"
	\t\t\t\t\t\t<input type=\"submit\" name=\"rplus\" value=\"R+\"">>,
							RatingEnabled, <<"/>
	\t\t\t\t\t</form>
	\t\t\t\t</td>
	\t\t\t\t<">>, AlbumTag, <<">">>, ArtistQuot, <<" (">>,
			format_date(Song), <<"): ">>, AlbumQuot, DiscInfo,
			<<"</">>, AlbumTag, <<">
	\t\t\t\t<td>
	\t\t\t\t\t<form method=\"post\" action=\"add_album.erl\">">>,
			InputForAlbum, <<"
	\t\t\t\t\t\t<input type=\"hidden\" name=\"disc\" value=\"">>,
					integer_to_binary(Disc), <<"\"/>
	\t\t\t\t\t\t<input type=\"submit\" name=\"add_here\" value=\"A\"/>
	\t\t\t\t\t\t<input type=\"submit\" name=\"add_end\" value=\"a\"/>
	\t\t\t\t\t</form>
	\t\t\t\t</td>
	\t\t\t</tr>\n">>].

format_artist(Song) ->
	quote_xml(format_artist_noquot(Song)).

format_artist_noquot(Song) ->
	proplists:get_value('AlbumArtist', Song,
		proplists:get_value('Artist', Song, <<"(unknown artist)">>)).

normalize_for_id(Str) -> lists:map(fun normalize_id_char/1,
				lists:flatten(io_lib:format("~s", [Str]))).
% https://www.w3.org/TR/html401/types.html#type-name -- [A-Za-z0-9-_:.]
normalize_id_char(Chr) when ((Chr >= $A) and (Chr =< $Z)) -> Chr;
normalize_id_char(Chr) when ((Chr >= $a) and (Chr =< $z)) -> Chr;
normalize_id_char(Chr) when ((Chr >= $0) and (Chr =< $9)) -> Chr;
normalize_id_char($-)                                     -> $-;
normalize_id_char($_)                                     -> $_;
normalize_id_char($:)                                     -> $:;
normalize_id_char($.)                                     -> $.;
normalize_id_char(_Other)                                 -> $_.

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
format_rating(?RATING_NOTPOSS) -> <<"-rat-">>;
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

respond_tab_albums(MPD, Req) ->
	respond_tab_songs_cb(MPD, Req, fun accumulate_row_album/4,
							<<"albums.xhtml">>).

accumulate_row_album(Conn, Song, Return, {Meta, Acc}) ->
	SMeta = {proplists:get_value('Album', Song),
					proplists:get_value('Disc', Song, -1)},
	{SMeta, case SMeta =:= Meta of
		true  -> Acc;
		false -> [format_header(Conn, Song, Return, <<"td">>)|Acc]
	end}.

respond_tab_files(Files, Req) ->
	respond_with_page([format_file(F) || F <- Files],
							<<"files.xhtml">>, Req).

format_file(File) ->
	{ok, ContentsRaw} = file:read_file(File),
	[<<"\t\t<h2>">>, File, <<"</h2>\n\t\t<pre>">>, quote_xml(ContentsRaw),
	<<"</pre>\n\t\t<hr/>\n">>].

process_add_album(MPD, Req) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	{Filter, Return} = form_to_filter_and_return(Form),

	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	SongsURIs = [proplists:get_value(file, Song)
			|| Song <- sort_songs(erlmpd:find(Conn, Filter))],

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
	redirect(Return, Req).

% TODO x SECURITY FORM VALUE DIRECTLY TO MPD - VALIDATE BEFORE!
form_to_filter_and_return(Form) ->
	Artist  = proplists:get_value("artist", Form),
	Album   = proplists:get_value("album",  Form),
	Primary = [{tagop, albumartist, eq, Artist},
		   {tagop, album,       eq, Album}],
	Filter  = {land, case proplists:get_value("disc", Form, "-1") of
			"-1" -> Primary;
			Disc -> Primary ++ [{tagop, disc, eq, Disc}]
			end},
	Anchor  = ["hdr_", normalize_for_id(Artist), "_",
						normalize_for_id(Album)],
	Return  = case proplists:get_value("return", Form) of
		"songs.xhtml"  -> "songs.xhtml#" ++ lists:flatten(Anchor);
		"albums.xhtml" -> "albums.xhtml#" ++ lists:flatten(Anchor);
		_Other         -> "index.xhtml"
		end,
	{Filter, Return}.

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
	% TODO MAKE ANCHOR FROM URI AND ADD IT TO ReturnTo
	erlmpd:disconnect(Conn),
	redirect(ReturnTo, Req).

process_modify_service(RadioOptions, Req) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	% TODO x security maybe its better to convert RadioOptions to list of lists and then do membership request in favor of list_to_atom
	GenToSet = list_to_atom(proplists:get_value("radio_generator", Form,
									"---")),
	?LOG_DEBUG("process_modify_server GenToSet=<~w>", [GenToSet]),
	case lists:member(GenToSet, RadioOptions) of
	true ->
		ok = gen_server:cast(maempsia_radio, {radio_start, GenToSet});
	false when GenToSet =:= '---' ->
		ok = gen_server:cast(maempsia_radio, radio_stop);
	_Any ->
		?LOG_WARNING("invalid form for radio_generator field")
	end,
	case proplists:get_value("podcast_start", Form) of
	"Start" ->
		ok = gen_server:cast(maempsia_podcast, podcast_start);
	_Other ->
		case proplists:get_value("podcast_stop", Form) of
		"Stop"  -> ok = gen_server:cast(maempsia_podcast, podcast_stop);
		_Other2 -> ok
		end
	end,
	redirect("index.xhtml", Req).

process_modify_playlist(MPD, Req, ReturnTo) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	ID = list_to_integer(proplists:get_value("id", Form, 1)),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	case proplists:get_value("act_remove", Form) of
	undefined ->
		case proplists:get_value("act_play", Form) of
		undefined -> ?LOG_WARNING("no action for ~p", [Form]);
		_ActPlay  -> ok = erlmpd:playid(Conn, ID)
		end;
	_ActRemove ->
		ok = erlmpd:deleteid(Conn, ID)
	end,
	erlmpd:disconnect(Conn),
	redirect(ReturnTo, Req).

process_control_player(MPD, Req) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	Tasks = conditional_action(Form, "toggle_play_pause",
							fun toggle_pause/1) ++
		conditional_action(Form, "volume_up",
				fun(Conn) -> erlmpd:volume(Conn, +5) end) ++
		conditional_action(Form, "volume_down",
				fun(Conn) -> erlmpd:volume(Conn, -5) end),
	case Tasks of
	[] ->
		ok;
	_NonEmpty ->
		{ok, Conn} = maempsia_erlmpd:connect(MPD),
		lists:foreach(fun(Op) -> Op(Conn) end, Tasks),
		erlmpd:disconnect(Conn)
	end,
	redirect("index.xhtml", Req).

% maenmpc_ui.erl toggle_pause
toggle_pause(Conn) ->
	Status = erlmpd:status(Conn),
	case proplists:get_value(state, Status) of
	undefined -> ok; % Cannot do anyhting in undefined state
	play      -> erlmpd:pause(Conn, true);
	pause     -> erlmpd:pause(Conn, false);
	stop      -> erlmpd:play(Conn)
	end.

conditional_action(Form, Field, Op) ->
	case proplists:get_value(Field, Form) of
	undefined -> [];
	_EntrySet -> [Op]
	end.

% Currently works with album rating only...
process_update_rating(MPD, Req, Delta) ->
	Form = mochiweb_util:parse_qs(mochiweb_request:recv_body(Req)),
	{Filter, Return} = form_to_filter_and_return(Form),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	OldSticker = maempsia_erlmpd:get_album_rating_by_filter(Conn, Filter),
	if
	OldSticker =:= ?RATING_UNRATED ->
		ok = maempsia_erlmpd:set_album_rating_by_filter(Conn, Filter,
								6 + Delta);
	(OldSticker + Delta =< 0) or (OldSticker + Delta > 10) ->
		ok = maempsia_erlmpd:delete_album_rating_by_filter(
								Conn, Filter);
	true ->
		ok = maempsia_erlmpd:set_album_rating_by_filter(Conn, Filter,
							OldSticker + Delta)
	end,
	erlmpd:disconnect(Conn),
	redirect(Return, Req).
