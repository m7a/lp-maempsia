-module(maempsia_playcounts).
-export([run/2]).
-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

% key = {Artist, Album, Title}
-record(csong, {key, uri, count_sticker, count_scrobble}).

run(MPD, Maloja) ->
	MalojaConn = {maps:get(url, Maloja), maps:get(key, Maloja)},
	IgnoreScrobbles = sets:from_list(read_ignore_file(maps:get(ignore_file,
								Maloja))),
	ets:new(csongs, [set, private, named_table, {keypos, #csong.key}]),
	case with_connection(MPD, fun read_song_database/1) of
	ok ->
		read_assign_scrobbles(MalojaConn, IgnoreScrobbles),
		% open a new connection to apply the changes because reading
		% scrobbles may take arbitrarily long
		with_connection(MPD, fun apply_sticker_changes/1);
	Error ->
		?LOG_ERROR("Failed to read song DB ~p", [Error])
	end,
	% Discard the data after processing. Although they could in principle
	% be useful to pass on to follow-up computations such as Radio playlist
	% generation this would run counter to the idea that these are modular
	% additions which could run even without support of the playcounts
	% synchronization e.g. if the playCount variable is tracked by another
	% MPD client the radio should still be able to run.
	%   Additionally, the most resource-constrained deployment for MAEMPSIA
	% is the phone where this playcounts step is indeed intended to be
	% skipped as the phone operates on a copy of the database with the
	% playCount sticker readily populated.
	ets:delete(csongs).

read_ignore_file(undefined) -> [];
read_ignore_file(PossibleFile) ->
	case file:consult(PossibleFile) of
	{ok, [List]} ->
		List;
	{error, AnyError} ->
		?LOG_WARNING("Failed to read ~s: ~w", [PossibleFile, AnyError]),
		[]
	end.

with_connection(MPD, CB) ->
	case maempsia_erlmpd:connect(MPD) of
	{ok, Conn} -> CB(Conn);
	Error      -> {error, Error}
	end.

read_song_database(Conn) ->
	ok = erlmpd:tagtypes_clear(Conn),
	ok = erlmpd:tagtypes_enable(Conn, [track, artist, album, title,
								albumartist]),
	Filter = {lnot, {land, [
			{tagop, artist, eq, ""},
			{tagop, album,  eq, ""},
			{tagop, title,  eq, ""}
		]}},

	maempsia_erlmpd:foreach_song(Conn, Filter, fun(Entry) ->
		URI = proplists:get_value(file, Entry),
		% Querying the stickers in-line is a little bit slower than
		% batch processing but it greatly enhances the robustness
		% against timeouts in event of slow processing.
		SE = #csong{
			key = to_key(Entry),
			uri = URI,
			count_sticker = maempsia_erlmpd:get_playcount(Conn,
									URI),
			count_scrobble = 0
		},
		case ets:insert_new(csongs, SE) of
		true ->
			ok;
		false ->
			[OE] = ets:lookup(csongs, SE#csong.key),
			?LOG_INFO("Duplicate ~s/~s/~s -- ~s/~s~n",
					[element(1, SE#csong.key),
					element(2, SE#csong.key),
					element(3, SE#csong.key),
					SE#csong.uri, OE#csong.uri])
		end
	end).

% maenmpc_erlmpd.erl
to_key(Entry) ->
	{normalize_key(maempsia_erlmpd:get_artist(Entry)),
	 normalize_strong(proplists:get_value('Album', Entry, <<>>)),
	 normalize_key(proplists:get_value('Title', Entry, <<>>))}.

% Expensive normalization option required due to the fact that scrobbling or
% Maloja seem to mess with the supplied metadata. See also maempsia_scrobble.erl
normalize_key(V)    -> normalize_always(maempsia_erlmpd:normalize_safe(V)).
normalize_always(V) -> unicode:characters_to_nfc_binary(string:casefold(V)).
normalize_strong(V) -> normalize_always(maempsia_erlmpd:normalize_strong(V)).

read_assign_scrobbles(MalojaConn, IgnoreScrobbles) ->
	{Processed, Skipped} = foldl_scrobbles(fun(Scrobble, Stats) ->
			process_scrobble(IgnoreScrobbles, Scrobble, Stats)
		end, {0, 0}, MalojaConn),
	?LOG_INFO("~w of ~w scrobbles missed", [Skipped, Processed]).

% maenmpc_maloja.erl
foldl_scrobbles(_Callback, Acc, {none, none}) ->
	Acc;
foldl_scrobbles(Callback, Acc, API) ->
	% 1000 and multiples of it seem to work well. < 1000 was slow
	% performance and intermediate values like e.g. 1200 were also slow...
	foldl_scrobbles_inner(Callback, Acc, API,
					"apis/mlj_1/scrobbles?perpage=2000").

foldl_scrobbles_inner(_Callback, Acc, _API, null) ->
	Acc;
foldl_scrobbles_inner(Callback, Acc0, {URL, Key}, Page) ->
	?LOG_INFO("foldl_scrobbles_inner page=~s...", [Page]),
	{ok, {_Status, _Headers, AllScrobblesRaw}} = httpc:request(
					io_lib:format("~s~s&key=~s",
					[URL, Page, uri_string:quote(Key)])),
	JSON     = jiffy:decode(AllScrobblesRaw, [return_maps]),
	Acc1     = lists:foldl(Callback, Acc0, maps:get(<<"list">>, JSON)),
	NextPage = maps:get(<<"next_page">>, maps:get(<<"pagination">>, JSON)),
	foldl_scrobbles_inner(Callback, Acc1, {URL, Key}, NextPage).

process_scrobble(IgnoreScrobbles, Scrobble, {Proc, Skip}) ->
	TrackInfo = maps:get(<<"track">>, Scrobble),
	TitleRaw  = maps:get(<<"title">>, TrackInfo),
	AlbumInfo = maps:get(<<"album">>, TrackInfo),
	case (TrackInfo =:= null) or (TitleRaw =:= null) or
							(AlbumInfo =:= null) of
	true ->
		{Proc + 1, Skip};
	false ->
		PrimaryTitle = normalize_key(TitleRaw),
		Titles = [PrimaryTitle, normalize_strong(TitleRaw)]
			++
			case string:split(TitleRaw, " - ", all) of
			[A, B] -> [normalize_always([A, <<" (">>, B, <<")">>])];
			_Other -> []
			end,
		Album = normalize_strong(maps:get(<<"albumtitle">>, AlbumInfo)),
		% Prefer to assign by album artist
		%   In some cases it cannot be done then attempt to assign by
		% track artists. In the database, these may appear separated by
		% & in any order thus try out two orderings in case of exactly
		% two artists (otherwise give up on trying to construct
		% multi-artist match).
		%   Finally, for albums which are assigned
		% Album Artist = Various Artists, allow assigning this, too.
		% Note that his assignment is independent of whether there are
		% multiple artists on the scrobble at hand hence always provide
		% this option.
		Artists = maps:get(<<"artists">>, AlbumInfo) ++
				case maps:get(<<"artists">>, TrackInfo) of
				[A1|[A2|[]]] ->
					[[A1, <<" & ">>, A2]|
					[[A2, <<" & ">>, A1]|
					[A1|[A2|[]]]]];
				OtherArtists ->
					OtherArtists
				end ++ [<<"Various Artists">>],
		Match = lists:search(fun({Title, ArtistRaw}) ->
				length(ets:lookup(csongs, {normalize_key(
						ArtistRaw), Album, Title})) == 1
			end, [{Title, ArtistRaw} ||
				Title <- Titles, ArtistRaw <- Artists]),
		case Match of
		{value, {Title, ArtistRaw}} ->
			ets:update_counter(csongs, {normalize_key(ArtistRaw),
				Album, Title}, {#csong.count_scrobble, 1}),
			{Proc + 1, Skip};
		false ->
			[PrimaryArtistRaw|_T] = Artists,
			PrimaryArtist = normalize_key(PrimaryArtistRaw),
			case sets:is_element({PrimaryArtist, Album,
						PrimaryTitle}, IgnoreScrobbles)
					or sets:is_element({PrimaryArtist,
						Album, any}, IgnoreScrobbles) of
			true ->
				{Proc, Skip};
			false ->
				?LOG_INFO("Unknown scrobble <~s/~s/~s>",
						[lists:nth(1, Artists), Album,
						lists:nth(1, Titles)]),
				{Proc + 1, Skip + 1}
			end
		end
	end.

apply_sticker_changes(Conn) ->
	lists:foreach(fun(IEnt) ->
		?LOG_INFO("Ignore sticker ~w > ~w scrobbles [~s/~s/~s] ~s",
			[IEnt#csong.count_sticker, IEnt#csong.count_scrobble,
			element(1, IEnt#csong.key), element(2, IEnt#csong.key),
			element(3, IEnt#csong.key), IEnt#csong.uri])
	end, ets:select(csongs, ets:fun2ms(fun(X)
		when X#csong.count_sticker > X#csong.count_scrobble -> X
	end))),

	lists:foreach(fun(AEnt) ->
		NewCount = AEnt#csong.count_scrobble,
		?LOG_INFO("Update sticker ~w -> ~w [~s/~s/~s]~n",
			[AEnt#csong.count_sticker, NewCount,
			element(1, AEnt#csong.key), element(2, AEnt#csong.key),
			element(3, AEnt#csong.key)]),
		ok = erlmpd:sticker_set(Conn, "song", AEnt#csong.uri,
					"playCount", integer_to_list(NewCount))
	end, ets:select(csongs, ets:fun2ms(fun(X)
		when X#csong.count_sticker < X#csong.count_scrobble -> X
	end))).
