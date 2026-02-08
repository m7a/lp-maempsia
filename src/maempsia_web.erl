-module(maempsia_web).
-author("Linux-Fan, Ma_Sys.ma <info@masysma.net>").
-export([start/1, stop/0]).

-define(RATING_UNRATED, -1).

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

% --------------------------------------------------------------------[ Code ]--
start(Options) ->
	MPD = proplists:get_value(mpd, Options),
	ServerOptions = proplists:delete(mpd, Options),
	mochiweb_http:start([{name, ?MODULE}|[{loop, fun(Req) ->
							loop(MPD, Req)
						end}|ServerOptions]]).

stop() ->
	mochiweb_http:stop(?MODULE).

loop(MPD, Req) ->
	Method = mochiweb_request:get(method, Req),
	case mochiweb_request:get(path, Req) of
	% start
	"/" when Method =:= 'GET'; Method =:= 'HEAD' ->
		redirect("index.xhtml", Req);
	% pages
	"/index.xhtml" when Method =:= 'GET'; Method =:= 'HEAD' ->
		respond_tab_start(MPD, Req);
	"/playlist.xhtml" when Method =:= 'GET'; Method =:= 'HEAD' ->
		respond_tab_playlist(MPD, Req);
	"/songs.xhtml" when Method =:= 'GET'; Method =:= 'POST' ->
		respond_tab_songs(MPD, Req);
	% control
	"/add_album.erl" when Method =:= 'POST' ->
		process_add_album(MPD, Req);
	"/add_song_from_songs.erl" when Method =:= 'POST' ->
		process_add_song(MPD, Req, "songs.xhtml");
	_Other ->
		mochiweb_request:respond({404, [{"Content-Type", "text/plain"}],
					"not found\n"}, Req)
	end.

redirect(Target, Req) ->
	mochiweb_request:respond({302, [{"Location", Target}], ""}, Req).

respond_tab_start(_MPD, Req) ->
	respond_with_page(<<"Hello world">>, <<"index.xhtml">>, Req).

respond_with_page(Text, OnPage, Req) ->
	mochiweb_request:respond({200, [
		{"Content-Type", "application/xhtml+xml; charset=UTF-8"}
	], [
		?XHTML_TPL_TOP,
		generate_navigation(OnPage),
		Text,
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

respond_tab_playlist(_MPD, Req) ->
	% TODO NEXT - FILL IN PLAYLIST TAB
	respond_with_page(<<"Hello world">>, <<"playlist.xhtml">>, Req).

respond_tab_songs(MPD, Req) ->
	{ok, Conn} = erlmpd_connect(MPD),
	Rows = [generate_songs_rows(Conn, Artist) ||
				Artist <- erlmpd:list(Conn, albumartist)],
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

erlmpd_connect(MPD) ->
	{Host, Port} = maps:get(ip, MPD),
	erlmpd:connect(Host, Port).

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
	ArtistQuot = quote_xml(proplists:get_value('AlbumArtist', Song,
		proplists:get_value('Artist', Song, <<"(unknown artist)">>))),
	AlbumQuot = quote_xml(proplists:get_value('Album', Song,
							<<"(unknown album)">>)),
	Disc = proplists:get_value('Disc', Song, -1),
	DiscInfo = case Disc of
			-1    -> <<>>;
			1     -> <<>>;
			_Disc -> [<<" (">>, integer_to_binary(Disc), <<")">>]
		end,
	[<<"\t\t\t\t<tr><th colspan=\"4\">">>, ArtistQuot,
	<<" (">>, quote_xml(proplists:get_value('Date', Song, <<"?">>)),
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
	TitleQuot = quote_xml(proplists:get_value('Title', Song,
							<<"(untitled)">>)),
	URI = proplists:get_value(file, Song),
	[<<"\t\t\t\t<tr><td>
	\t\t\t\t<form method=\"post\" action=\"add_song_from_songs.erl\">
	\t\t\t\t\t<input type=\"hidden\" name=\"file\" value=\"">>,
							quote_xml(URI), <<"\"/>
	\t\t\t\t\t<input type=\"submit\" name=\"add_end\" value=\"a\"/>
	\t\t\t\t\t<input type=\"submit\" name=\"add_here\" value=\"A\"/>
	\t\t\t\t</form>
	\t\t\t</td><td>">>,
	format_rating(rating_for_uri(URI, Conn)),
	<<"</td><td>">>,
	integer_to_binary(proplists:get_value('Track', Song, 0)),
	<<"</td><td>">>,
	TitleQuot,
	<<"</td><td>">>,
	format_duration(max(1, proplists:get_value('Time', Song, 1))),
	<<"</td></tr>\n">>].

rating_for_uri(URI, Conn) ->
	case erlmpd:sticker_get(Conn, "song", binary_to_list(URI), "rating") of
	{error, _Any} -> ?RATING_UNRATED;
	ProperRating  -> list_to_integer(ProperRating)
	end.

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

format_duration(Duration) ->
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

	{ok, Conn} = erlmpd_connect(MPD),
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
	{ok, Conn} = erlmpd_connect(MPD),
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
