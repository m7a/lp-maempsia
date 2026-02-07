-module(maempsia_web).
-author("Linux-Fan, Ma_Sys.ma <info@masysma.net>").
-export([start/1, stop/0]).

start(Options) ->
	io:fwrite("options=<~p>~n", [Options]),
	mochiweb_http:start([{name, ?MODULE}|[{loop, fun loop/1}|Options]]).

stop() ->
	mochiweb_http:stop(?MODULE).

loop(Req) ->
	Method = mochiweb_request:get(method, Req),
	case mochiweb_request:get(path, Req) of
	"/" ++ Path when Method =:= 'GET'; Method =:= 'HEAD' ->
		io:fwrite("REQUEST ~p~n", [Path]),
		mochiweb_request:respond({200, [{"Content-Type", "text/plain"}],
					"Hello world\n"}, Req);
	_Other ->
		mochiweb_request:respond({404, [{"Content-Type", "text/plain"}],
					"not found\n"}, Req)
	end.
