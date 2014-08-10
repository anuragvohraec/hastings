%% Copyright 2014 Cloudant

-module(hastings_index).
-behavior(gen_server).


-include_lib("couch/include/couch_db.hrl").
-include("hastings.hrl").


-export([
    start_link/4,
    stop/1,

    destroy/1,
    design_doc_to_index/2,

    add_monitor/2,

    await/2,
    search/2,
    info/1,

    set_update_seq/2,
    update/3,
    remove/2
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3
]).


-record(st, {
    manager,
    index,
    dbpid,
    updater_pid,
    waiting_list = [],
    generation
}).


start_link(Manager, DbName, Index, Generation) ->
    proc_lib:start_link(?MODULE, init, [{Manager, DbName, Index, Generation}]).


stop(Pid) ->
    Ref = erlang:monitor(process, Pid),
    try
        case gen_server:call(Pid, stop) of
            false ->
                false;
            ok ->
                receive
                    {'DOWN', Ref, _, _, _} ->
                        ok
                after 50000 ->
                    throw({timeout, closing_index})
                end
        end
    after
        erlang:demonitor(Ref, [flush])
    end.


destroy(IndexDir) ->
    easton_index:destroy(IndexDir).


design_doc_to_index(#doc{id=Id, body={Fields}}, IndexName) ->
    try
        design_doc_to_index_int(Id, Fields, IndexName)
    catch throw:Error ->
        Error
    end.


add_monitor(Pid, {Client, _}) ->
    add_monitor(Pid, Client);

add_monitor(Pid, Client) when is_pid(Client) ->
    gen_server:cast(Pid, {add_monitor, Client}).


await(Pid, MinSeq) ->
    gen_server:call(Pid, {await, MinSeq}, infinity).


search(Pid, QueryArgs) ->
    gen_server:call(Pid, {search, QueryArgs}, infinity).


info(Pid) ->
    gen_server:call(Pid, info, infinity).


set_update_seq(Pid, NewCurrSeq) ->
    gen_server:call(Pid, {new_seq, NewCurrSeq}, infinity).


update(Pid, Id, Geoms) ->
    gen_server:call(Pid, {update, Id, Geoms}, infinity).


remove(Pid, Id) ->
    gen_server:call(Pid, {remove, Id}, infinity).


init({Manager, DbName, Index, Generation}) ->
    process_flag(trap_exit, true),
    erlang:send_after(get_timeout(), self(), run_checks),
    case open_index(DbName, Index) of
        {ok, NewIndex} ->
            {ok, Db} = couch_db:open_int(DbName, []),
            try
                couch_db:monitor(Db)
            after
                couch_db:close(Db)
            end,
            proc_lib:init_ack({ok, self()}),
            St = #st{
                manager = Manager,
                index = NewIndex,
                dbpid = Db#db.main_pid,
                generation = Generation
            },
            gen_server:enter_loop(?MODULE, [], St);
        Error ->
            proc_lib:init_ack(Error)
    end.


terminate(_Reason, St) ->
    Index = St#st.index,
    catch exit(St#st.updater_pid, kill),
    ok = easton_index:close(Index#h_idx.pid).


handle_call(stop, _From, St) ->
    % We know that the index manager will send us
    % no more clients after this message but we may
    % have a message in our mailbox. This means
    % we need to check if there's a client that just
    % came in before we check if we need to stop.
    case add_last_monitors() of
        true ->
            {reply, false, St};
        false ->
            {stop, normal, ok, St}
    end;

handle_call({await, RequestSeq}, From, St) ->
    #st{
        index = #h_idx{update_seq = Seq} = Index,
        updater_pid = UpPid,
        waiting_list = WaitList
    } = St,
    case {RequestSeq, Seq, UpPid} of
        _ when RequestSeq =< Seq ->
            {reply, ok, St};
        _ when RequestSeq > Seq andalso UpPid == undefined ->
            Pid = spawn_link(hastings_index_updater, update, [self(), Index]),
            {noreply, St#st{
                updater_pid = Pid,
                waiting_list = [{From, RequestSeq} | WaitList]
            }};
        _ when RequestSeq > Seq andalso UpPid /= undefined ->
            {noreply, St#st{
                waiting_list = [{From, RequestSeq} | WaitList]
            }}
    end;

handle_call({search, HQArgs}, _From, St) ->
    Idx = St#st.index,
    Geom = HQArgs#h_args.geom,
    Opts = [
        {filter, HQArgs#h_args.filter},
        {nearest, HQArgs#h_args.nearest},
        {req_srid, HQArgs#h_args.req_srid},
        {resp_srid, HQArgs#h_args.resp_srid},
        {vbox, HQArgs#h_args.vbox},
        {t_start, HQArgs#h_args.t_start},
        {t_end, HQArgs#h_args.t_end},
        {limit, HQArgs#h_args.limit + HQArgs#h_args.skip},
        {include_geom, HQArgs#h_args.include_geoms},
        {bookmark, HQArgs#h_args.bookmark}
    ],
    Resp = try
        easton_index:search(Idx#h_idx.pid, Geom, Opts)
    catch throw:Error ->
        Error
    end,
    {reply, Resp, St};

handle_call(info, _From, St) ->
    Idx = St#st.index,
    {ok, Info} = easton_index:info(Idx#h_idx.pid),
    {reply, {ok, Info}, St};

handle_call({new_seq, Seq}, _From, St) ->
    Idx = St#st.index,
    ok = easton_index:put(Idx#h_idx.pid, update_seq, Seq),
    {reply, ok, St};

handle_call({update, Id, Geoms}, _From, St) ->
    Idx = St#st.index,
    Resp = (catch easton_index:update(Idx#h_idx.pid, Id, Geoms)),
    {reply, Resp, St};

handle_call({remove, Id}, _From, St) ->
    Idx = St#st.index,
    Resp = (catch easton_index:remove(Idx#h_idx.pid, Id)),
    {reply, Resp, St}.


handle_cast({add_monitor, Pid}, St) ->
    erlang:monitor(process, Pid),
    {noreply, St};

handle_cast(_Msg, St) ->
    {noreply, St}.


handle_info(run_checks, St) ->
    erlang:send_after(get_timeout(), self(), run_checks),
    case has_clients(St) of
        true ->
            ok;
        false ->
            Msg = {gen_check, self(), St#st.generation},
            gen_server:cast(St#st.manager, Msg)
    end,
    {noreply, St};

handle_info({'EXIT', Pid, {updated, NewSeq}}, #st{updater_pid = Pid} = St) ->
    Index0 = St#st.index,
    Index = Index0#h_idx{update_seq = NewSeq},
    NewSt = case reply_with_index(Index, St#st.waiting_list) of
        [] ->
            St#st{
                index = Index,
                updater_pid = undefined,
                waiting_list = []
            };
        StillWaiting ->
            Pid = spawn_link(hastings_index_updater, update, [self(), Index]),
            St#st{
                index = Index,
                updater_pid = Pid,
                waiting_list = StillWaiting
            }
    end,
    {noreply, NewSt};
handle_info({'EXIT', Pid, Reason}, #st{updater_pid=Pid} = St) ->
    Fmt = "~s ~s closing: Updater pid ~p closing w/ reason ~w",
    ?LOG_INFO(Fmt, [?MODULE, index_name(St#st.index), Pid, Reason]),
    [gen_server:reply(P, {error, Reason}) || {P, _} <- St#st.waiting_list],
    {stop, normal, St};
handle_info({'EXIT', Pid, Reason}, #st{index=#h_idx{pid={Pid}}} = St) ->
    Fmt = "Index for ~s closed with reason ~w",
    ?LOG_INFO(Fmt, [index_name(St#st.index), Reason]),
    [gen_server:reply(P, {error, Reason}) || {P, _} <- St#st.waiting_list],
    {stop, normal, St};
handle_info({'DOWN', _, _, DbPid, Reason}, #st{dbpid=DbPid} = St) ->
    Fmt = "~s ~s closing: Db pid ~p closing w/ reason ~w",
    ?LOG_DEBUG(Fmt, [?MODULE, index_name(St#st.index), DbPid, Reason]),
    [gen_server:reply(P, {error, Reason}) || {P, _} <- St#st.waiting_list],
    {stop, normal, St};
handle_info({'DOWN', _, _, _, _}, St) ->
    {noreply, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


open_index(DbName, Idx) ->
    IdxDir = index_directory(DbName, Idx#h_idx.sig),
    Opts = [
        {type, Idx#h_idx.type},
        {dimensions, Idx#h_idx.dimensions},
        {srid, Idx#h_idx.srid}
    ],
    case easton_index:open(IdxDir, Opts) of
        {ok, Pid} ->
            UpdateSeq = easton_index:get(Pid, update_seq, 0),
            {ok, Idx#h_idx{
                pid = Pid,
                dbname = DbName,
                update_seq = UpdateSeq
            }};
        Error ->
            Error
    end.


reply_with_index(Index, WaitList) ->
    lists:foldl(fun({From, ReqSeq} = W, Acc) ->
        case ReqSeq =< Index#h_idx.update_seq of
            true ->
                gen_server:reply(From, ok),
                Acc;
            false ->
                [W | Acc]
        end
    end, [], WaitList).


has_clients(St) ->
    DbPid = St#st.dbpid,
    {monitors, Monitors} = process_info(self(), monitors),
    case Monitors of
        [] ->
            false;
        [{process, DbPid}] ->
            false;
        _Else ->
            true
    end.


add_last_monitors() ->
    add_last_monitors(false).


add_last_monitors(Resp) ->
    receive
        {'$gen_cast', {add_monitor, Client}} ->
            erlang:monitor(process, Client),
            add_last_monitors(true)
    after 0 ->
        Resp
    end.


design_doc_to_index_int(Id, Fields, IndexName) ->
    {RawIndexes} = case couch_util:get_value(<<"st_indexes">>, Fields) of
        undefined ->
            {[]};
        {_} = RI ->
            RI;
        Else ->
            throw({invalid_index_object, Else})
    end,
    case lists:keyfind(IndexName, 1, RawIndexes) of
        false ->
            throw({not_found, <<IndexName/binary, " not found.">>});
        {IndexName, {IdxProps}} ->
            Idx = #h_idx{
                ddoc_id = Id,
                name = IndexName,
                def = get_index_def(IdxProps),
                lang = get_index_lang(Fields),

                type = get_index_type(IdxProps),
                dimensions = get_index_dimensions(IdxProps),
                srid = get_index_srid(IdxProps)
            },
            {ok, set_index_sig(Idx)};
        _ ->
            throw({invalid_index, <<IndexName/binary, " is invalid.">>})
    end.


set_index_sig(Idx) ->
    SigTerm = {
        Idx#h_idx.def,
        Idx#h_idx.type,
        Idx#h_idx.dimensions,
        Idx#h_idx.srid
    },
    Sig = ?l2b(couch_util:to_hex(couch_util:md5(term_to_binary(SigTerm)))),
    Idx#h_idx{sig = Sig}.


get_index_def(IdxProps) ->
    case couch_util:get_value(<<"index">>, IdxProps) of
        Bin when is_binary(Bin) ->
            Bin;
        undefined ->
            throw({invalid_index_definition, not_found});
        Else ->
            throw({invalid_index_definition, Else})
    end.


get_index_lang(Fields) ->
    Lang = couch_util:get_value(<<"language">>, Fields, <<"javascript">>),
    if is_binary(Lang) -> ok; true ->
        throw({invalid_index_language, Lang})
    end,
    Lang.


get_index_type(IdxProps) ->
    case couch_util:get_value(<<"type">>, IdxProps, <<"rtree">>) of
        <<"rtree">> -> <<"rtree">>;
        <<"tprtree">> -> <<"tprtree">>;
        Else -> throw({invalid_index_type, Else})
    end.


get_index_dimensions(IdxProps) ->
    case couch_util:get_value(<<"dimensions">>, IdxProps, undefined) of
        N when N == 2; N == 3; N == 4 ->
            N;
        undefined ->
            case couch_util:get_value(<<"dimension">>, IdxProps, 2) of
                N when N == 2; N == 3; N == 4 ->
                    N;
                Else2 ->
                    throw({invalid_index_dimensions, Else2})
            end;
        Else1 ->
            throw({invalid_index_dimensions, Else1})
    end.


get_index_srid(IdxProps) ->
    case couch_util:get_value(<<"srid">>, IdxProps, 4326) of
        N when is_integer(N), N > 0 ->
            N;
        B when is_binary(B) ->
            parse_srid(B);
        Else ->
            throw({invalid_index_srid, Else})
    end.


parse_srid(<<"urn:ogc:def:crs:EPSG::", Tail/binary>> = Val) ->
    try
        SRID = integer_to_list(binary_to_list(Tail)),
        if SRID > 0 -> ok; true ->
            throw(bad_srid)
        end,
        SRID
    catch _:_ ->
        throw({error, {invalid_srid, Val}})
    end.


index_name(#h_idx{dbname=DbName, ddoc_id=DDocId, name=IndexName}) ->
    <<DbName/binary, " ", DDocId/binary, " ", IndexName/binary>>.


index_directory(DbName, Sig) ->
    GeoDir = config:get("couchdb", "geo_index_dir", "/srv/geo_index"),
    filename:join([GeoDir, DbName, Sig]).


get_timeout() ->
    TO = config:get("hastings", "index_timeout", "60000"),
    try
        list_to_integer(TO)
    catch _:_ ->
        60000
    end.
