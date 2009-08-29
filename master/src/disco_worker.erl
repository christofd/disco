
-module(disco_worker).
-behaviour(gen_server).

-export([start_link/1, start_link_remote/4, remote_worker/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
        terminate/2, code_change/3, slave_name/1]).

-include("task.hrl").
-record(state, {id, master, master_url, eventserv, port, task,
                child_pid, node, linecount, errlines, results, 
                last_msg, msg_counter, oob, oob_counter}).

-define(MAX_MSG_LENGTH, 8192).
-define(RATE_WINDOW, 100000). % 100ms
-define(RATE_LIMIT, 10).
-define(OOB_MAX, 1000).
-define(OOB_KEY_MAX, 256).

-define(SLAVE_ARGS, "+K true").
-define(CMD, "nice -n 19 disco-worker '~s' '~s' '~s' '~s' '~w' ~s").
-define(PORT_OPT, [{line, 100000}, binary, exit_status,
                   use_stdio, stderr_to_stdout, 
                   {env, [{"LD_LIBRARY_PATH", "lib"}]}]).

get_env(Var) ->
        get_env(Var, lists:flatten(io_lib:format(" -env ~s ~~s", [Var]))).

get_env(Var, Fmt) ->
        case os:getenv(Var) of
                false -> "";
                Val -> io_lib:format(Fmt, [Val])
        end.

slave_env() ->
        lists:flatten([?SLAVE_ARGS, 
                get_env("DISCO_HOME", " -pa ~s/ebin"),
                [get_env(X) || X <- ["DISCO_MASTER_PORT", "DISCO_ROOT",
                        "DISCO_PORT", "DISCO_FLAGS", "PYTHONPATH", "PATH"]]]).

slave_name(Node) ->
        {ok, Name} = application:get_env(disco_name),
        SName = lists:flatten([Name, "_slave"]),
        list_to_atom(SName ++ "@" ++ Node).

start_link_remote(Master, EventServ, Node, Task) ->
        NodeAtom = slave_name(Node),
        JobName = Task#task.jobname,
        error_logger:info_report(["Starting a worker at ", Node, self()]),

        case net_adm:ping(NodeAtom) of
                pong -> ok;
                pang -> 
                        slave_master ! {start, self(), Node, slave_env()},
                        receive
                                slave_started -> ok;
                                {slave_failed, X} ->
                                        event_server:event(JobName,
                                                "WARN: Node failure: ~p", [X], []),
                                        exit({data_error, Task#task.input})
                        after 60000 ->
                                exit({data_error, Task#task.input})
                        end
        end,
        process_flag(trap_exit, true),

        {ok, MasterUrl0} = application:get_env(disco_url),
        MasterUrl = MasterUrl0 ++ disco_server:jobhome(JobName),

        spawn_link(NodeAtom, disco_worker, remote_worker,
                 [[self(), Master, MasterUrl, EventServ, Task, Node]]),
        
        receive
                ok -> ok;
                timeout -> 
                        event_server:event(JobName,
                                "WARN: Worker timeout on ~s", [Node], []),
                        exit({data_error, Task#task.input});
                {'EXIT', _, Reason} -> exit(Reason);
                _ -> exit({error, invalid_reply})
        after 60000 ->
                event_server:event(JobName,
                        "WARN: Worker timeout on ~s", [Node], []),
                exit({data_error, Task#task.input})
        end,
        wait_for_exit().

remote_worker(Args) ->
        process_flag(trap_exit, true),
        start_link(Args),
        wait_for_exit().

wait_for_exit() ->
        receive
                {'EXIT', _, Reason} -> exit(Reason)
        end.

start_link([Parent|_] = Args) ->
        error_logger:info_report(["Worker starting at ", node(), Parent]),
        Worker = gen_server:start_link(disco_worker, Args, []),
        % NB: start_worker call is known to timeout if the node is really
        % busy - it should not be a fatal problem
        case catch gen_server:call(Worker, start_worker, 30000) of
                ok -> Parent ! ok;
                _ -> Parent ! timeout
        end.

init([Id, Master, MasterUrl, EventServ, Task, Node]) ->
        process_flag(trap_exit, true),
        error_logger:info_report(
                {"Init worker ", Task#task.jobname, " at ", node()}),
        erlang:monitor(process, Task#task.from),
        {ok, #state{id = Id, 
                    master = Master,
                    master_url = MasterUrl,
                    task = Task,
                    node = Node,
                    child_pid = none, 
                    eventserv = EventServ,
                    linecount = 0,
                    last_msg = now(),
                    msg_counter = 0,
                    oob = [],
                    oob_counter = 0,
                    errlines = [],
                    results = []}}.

handle_call(start_worker, _From, State) ->
        Cmd = spawn_cmd(State),
        error_logger:info_report(["Spawn cmd: ", Cmd]),
        Port = open_port({spawn, Cmd}, ?PORT_OPT),
        {reply, ok, State#state{port = Port}, 30000}.

spawn_cmd(#state{task = T, node = Node, master_url = Url}) ->
        lists:flatten(io_lib:fwrite(?CMD,
                [T#task.mode, T#task.jobname, Node, Url, 
                        T#task.taskid, T#task.input])).

strip_timestamp(Msg) when is_binary(Msg) ->
        strip_timestamp(binary_to_list(Msg));
strip_timestamp(Msg) ->
        P = string:chr(Msg, $]),
        if P == 0 ->
                Msg;
        true ->
                string:substr(Msg, P + 2)
        end.

event(#state{task = T, eventserv = EvServ, node = Node}, "WARN", Msg) ->
        event_server:event(EvServ, Node, T#task.jobname,
                "~s [~s:~B] ~s", ["WARN", T#task.mode, T#task.taskid, Msg],
                        {task_failed, T#task.mode});

event(#state{task = T, eventserv = EvServ, node = Node}, Type, Msg) ->
        event_server:event(EvServ, Node, T#task.jobname,
                "~s [~s:~B] ~s", [Type, T#task.mode, T#task.taskid, Msg], []).

handle_info({_, {data, {eol, <<"**<PID>", Line/binary>>}}}, S) ->
        {noreply, S#state{child_pid = binary_to_list(Line)}}; 

handle_info({_, {data, {eol, <<"**<MSG>", Line0/binary>>}}}, S) ->
        if size(Line0) > ?MAX_MSG_LENGTH ->
                <<Line:?MAX_MSG_LENGTH/binary, _/binary>> = Line0;
        true ->
                Line = Line0
        end,

        T = now(),
        D = timer:now_diff(T, S#state.last_msg),
        event(S, "", strip_timestamp(Line)),
        S1 = S#state{last_msg = T, linecount = S#state.linecount + 1},
        
        if D > ?RATE_WINDOW ->
                {noreply, S1#state{msg_counter = 1}};
        S1#state.msg_counter > ?RATE_LIMIT ->
                Err = "Message rate limit exceeded. Too many msg() calls.",
                event(S, "ERROR", Err),
                gen_server:cast(S#state.master, 
                        {exit_worker, S#state.id, {job_error, Err}}),
                {stop, normal, S1};
        true ->
                {noreply, S1#state{msg_counter = S1#state.msg_counter + 1}}
        end;

handle_info({_, {data, {eol, <<"**<ERR>", Line/binary>>}}}, S) ->
        M = strip_timestamp(Line),
        event(S, "ERROR", M),
        gen_server:cast(S#state.master,
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S};

handle_info({_, {data, {eol, <<"**<DAT>", Line/binary>>}}}, S) ->
        M = strip_timestamp(Line),
        event(S, "WARN", M ++ [10] ++ S#state.errlines),
        T = S#state.task,
        gen_server:cast(S#state.master, {exit_worker, S#state.id,
                {data_error, {M, T#task.input}}}),
        {stop, normal, S};

handle_info({_, {data, {eol, <<"**<OUT>", Line/binary>>}}}, S) ->
        {noreply, S#state{results = strip_timestamp(Line)}};

handle_info({_, {data, {eol, <<"**<END>", Line/binary>>}}}, S) ->
        event(S, "", strip_timestamp(Line)),
        gen_server:cast(S#state.master, 
                {exit_worker, S#state.id,
                        {job_ok, {S#state.oob, S#state.results}}}),
        {stop, normal, S};

handle_info({_, {data, {eol, <<"**<OOB>", Line/binary>>}}}, S) ->
        [Key|Path] = string:tokens(binary_to_list(Line), " "),

        S1 = S#state{oob = [{Key, Path}|S#state.oob],
                     oob_counter = S#state.oob_counter + 1},

        if length(Key) > ?OOB_KEY_MAX ->
                Err = "OOB key too long: Max 256 characters",
                event(S, "ERROR", Err), 
                gen_server:cast(S#state.master,
                        {exit_worker, S#state.id, {job_error, Err}}),
                {stop, normal, S1};
        S#state.oob_counter > ?OOB_MAX ->
                Err = "OOB message limit exceeded. Too many put() calls.",
                event(S, "ERROR", Err), 
                gen_server:cast(S#state.master,
                        {exit_worker, S#state.id, {job_error, Err}}),
                {stop, normal, S1};
        true ->
                {noreply, S1}
        end;

handle_info({_, {data, {eol, <<"**", _/binary>> = Line}}}, S) ->
        event(S, "WARN", "Unknown line ID: " ++ binary_to_list(Line)),
        {noreply, S};               

handle_info({_, {data, {eol, Line}}}, S) ->
        {noreply, S#state{errlines = S#state.errlines 
                ++ binary_to_list(Line) ++ [10]}};

handle_info({_, {data, {noeol, Line}}}, S) ->
        event(S, "WARN", "Truncated line: " ++ binary_to_list(Line)),
        {noreply, S};

handle_info({_, {exit_status, _Status}}, #state{linecount = 0} = S) ->
        M =  "Worker didn't start:\n" ++ S#state.errlines,
        event(S, "WARN", M),
        T = S#state.task,
        gen_server:cast(S#state.master, {exit_worker, S#state.id,
                {data_error, {M, T#task.input}}}),
        {stop, normal, S};

handle_info({_, {exit_status, _Status}}, S) ->
        M =  "Worker failed. Last words:\n" ++ S#state.errlines,
        event(S, "ERROR", M),
        gen_server:cast(S#state.master,
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S};
        
handle_info({_, closed}, S) ->
        M = "Worker killed. Last words:\n" ++ S#state.errlines,
        event(S, "ERROR", M),
        gen_server:cast(S#state.master, 
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S};

handle_info(timeout, #state{linecount = 0} = S) ->
        M = "Worker didn't start in 30 seconds",
        event(S, "WARN", M),
        T = S#state.task,
        gen_server:cast(S#state.master, {exit_worker, S#state.id,
                {data_error, {M, T#task.input}}}),
        {stop, normal, S};

handle_info({'DOWN', _, _, _, _}, S) ->
        M = "Worker killed. Last words:\n" ++ S#state.errlines,
        event(S, "ERROR", M),
        gen_server:cast(S#state.master, 
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S}.

handle_cast(_, State) -> {noreply, State}.

terminate(_Reason, State) -> 
        % Possible bug: If we end up here before knowing child_pid, the
        % child may stay running. However, it may die by itself due to
        % SIGPIPE anyway.

        if State#state.child_pid =/= none ->
                % Kill child processes of the worker process
                os:cmd("pkill -9 -P " ++ State#state.child_pid),
                % Kill the worker process
                os:cmd("kill -9 " ++ State#state.child_pid);
        true -> ok
        end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.              



