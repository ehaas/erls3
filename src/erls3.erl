%%%-------------------------------------------------------------------
%%% File    : erls3.erl
%%% Author  : Andrew Birkett <andy@nobugs.org>
%%% Description : 
%%%
%%% Created : 14 Nov 2007 by Andrew Birkett <andy@nobugs.org>
%%%-------------------------------------------------------------------
-module(erls3).

-behaviour(application).
-define(TIMEOUT, 15000).
%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
     start/0,
	 start/2,
	 shutdown/0,
	 stop/1
	 ]).
%% API
-export([
      read_term/2, write_term/3,
	  list_buckets/0, create_bucket/1, 
	  delete_bucket/1, link_to/3, 
	  head/2, policy/1, get_objects/2, get_objects/3,
	  list_objects/2, list_objects/1, 
	  write_object/4, write_object/5, 
	  read_object/2, read_object/3, 
	  delete_object/2,
	  write_from_file/5,
	  read_to_file/3,
	  copy/4 ]).
	  

start()->
    application:start(sasl),
    application:start(crypto),
    application:start(xmerl),
    application:start(ibrowse),
    application:start(erls3).
    

start(_Type, _StartArgs) ->
    ID = get(access, "AMAZON_ACCESS_KEY_ID"),
    Secret = get(secret, "AMAZON_SECRET_ACCESS_KEY"),
    SSL = param(ssl, false),
    N = param(workers, 1),
    Memcached = param(memcached, false),
    UseMemcached = case Memcached of
        false ->
            false;
        FileName -> %ketama filename
            application:set_env(merle, file, FileName),
            merle:start(),
            true
    end,
    random:seed(),
    Timeout = param(timeout, ?TIMEOUT),
    Port = if SSL == true -> 
            ssl:start(),
            443;
        true -> 80
    end,
    ibrowse:set_max_sessions("erls3.amazonaws.com", Port,100),
    ibrowse:set_max_pipeline_size("erls3.amazonaws.com", Port,20),
    if ID == error orelse Secret == error ->
            {error, "AWS credentials not set. Pass as application parameters or as env variables."};
        true ->
            erls3sup:start_link([ID, Secret, SSL, Timeout, UseMemcached], N)
	end.
	
shutdown() ->
    application:stop(erls3).
    

link_to(Bucket, Key, Expires)->
    call({link_to, Bucket, Key, Expires} ).

create_bucket (Name) -> 
    call({put, Name} ).
delete_bucket (Name) -> 
    call({delete, Name} ).
list_buckets ()      -> 
    call({listbuckets}).

write_from_file(Bucket, Key, Filename, ContentType, Metadata)->
    call({from_file, Bucket, Key,Filename, ContentType, Metadata}).
    
read_to_file(Bucket, Key, Filename)->
    call({to_file, Bucket, Key, Filename}).
    
write_term(Bucket, Key, Term)->
    write_object (Bucket, Key,term_to_binary(Term), "application/poet", []).

write_object(Bucket, Key, Data, ContentType)->
    write_object (Bucket, Key, Data, ContentType, []).

write_object (Bucket, Key, Data, ContentType, Metadata) -> 
    call({put, Bucket, Key, Data, ContentType, Metadata}).

read_term(Bucket, Key)->
    case read_object (Bucket, Key) of
        {ok, {B, H}} -> {ok, {binary_to_term(B), H}};
        E -> E
    end.

copy(SrcBucket, SrcKey, DestBucket, DestKey)->
  call({copy, DestBucket, DestKey,[{"x-amz-copy-source", "/"++SrcBucket++"/" ++ SrcKey}]}).

head(Bucket, Key)->
    call({head, Bucket, Key}).

read_object (Bucket, Key, Etag) -> 
    call({get, Bucket, Key, Etag}).
    
read_object (Bucket, Key) -> 
    call({get, Bucket, Key}).
    
delete_object (Bucket, Key) -> 
    call({delete, Bucket, Key}).

    
% Gets objects in // from S3.
%% option example: [{delimiter, "/"},{maxkeys,10},{prefix,"/foo"}]
get_objects(Bucket, Options)->
  get_objects(Bucket, Options, fun(_B, Obj)-> Obj end).

% Fun = fun(Bucket, {Key, Content, Headers})
get_objects(Bucket, Options, Fun)->
    {ok, Objects} = list_objects(Bucket, Options),
    pmap(fun get_object/3,Objects, Bucket, Fun).
      
get_object({object_info, {"Key", Key}, _, _, _}, Bucket, Fun)->
  case call({get_with_key, Bucket, Key}) of
    {ok, Obj} -> Fun(Bucket, Obj);
    Error -> Error
  end.
%% option example: [{delimiter, "/"},{maxkeys,10},{prefix,"/foo"}]
list_objects (Bucket, Options ) -> 
    call({list, Bucket, Options }).
list_objects (Bucket) -> 
    list_objects( Bucket, [] ).


%  Sample policy file, 
% See : http://docs.amazonwebservices.com/AmazonS3/latest/index.html?HTTPPOSTForms.html
%{obj, [{"expiration", <<"2007-04-01T12:00:00.000Z">>}, 
%  {"conditions",  [
%      {obj, [{"acl", <<"public-read">>}]}, 
%      {obj,[{"bucket", <<"mybucket">>}]}, 
%      {obj,[{"x-amz-meta-user", <<"cstar">>}]}, 
%      [<<"starts-with">>, <<"$Content-Type">>, <<"image/">>],
%      [<<"starts-with">>, <<"$key">>, <<"/user/cstar">>]
%  ]}]}.
% erls3:policy will return : (helpful for building the form)
% [{"AWSAccessKeyId",<<"ACCESS">>},
% {"Policy",
%  <<"eyJleHBpcmF0aW9uIjoiMjAwNy0wNC0wMVQxMjowMDowMC4wMDBaIiwiY29uZGl0aW9ucyI6W3siYWNsIjoicHVibGljLXJlYWQi"...>>},
% {"Signature",<<"dNTpGLbdlz5KI+iQC6re8w5RnYc=">>},
% {"key",<<"/user/cstar">>},
% {"Content-Type",<<"image/">>},
% {"x-amz-meta-user",<<"cstar">>},
% {"bucket",<<"mybucket">>},
% {"acl",<<"public-read">>},
% {"file",<<>>}]
policy(Policy)->
    Pid = erls3sup:get_random_pid(),
    gen_server:call(Pid, {policy,Policy}).  
    
stop(_State) ->
    ok.


call(M)->
    call(M, 0).

call(M, Retries)->
    Pid = erls3sup:get_random_pid(),
    case gen_server:call(Pid, M, infinity) of
      retry -> 
          Sleep = random:uniform(trunc(math:pow(4, Retries)*10)),
          timer:sleep(Sleep),
          call(M, Retries + 1);   
     {timeout, _} ->
         Sleep = random:uniform(trunc(math:pow(4, Retries)*10)),
          timer:sleep(Sleep),
          call(M, Retries + 1);
      R -> R
  end.  
%%%%% Internal API stuff %%%%%%%%%
get(Atom, Env)->
    case application:get_env(Atom) of
     {ok, Value} ->
         Value;
     undefined ->
         case os:getenv(Env) of
     	false ->
     	    error;
     	Value ->
     	    Value
         end
    end.
    
param(Name, Default)->
	case application:get_env(?MODULE, Name) of
		{ok, Value} -> Value;
		_-> Default
	end.

%% Lifted from http://lukego.livejournal.com/6753.html	
pmap(_F,[], _Bucket, _Fun) -> [];
pmap(F,List, Bucket, Fun) ->
    Pid = self(),
    spawn(fun()->
        [spawn_worker(Pid,F,E, Bucket, Fun) || E <- List] 
    end),
        lists:map(fun(_N)->
            wait_result()
    end, lists:seq(1, length(List))).
spawn_worker(Parent, F, E, Bucket, Fun) ->
    spawn_link(fun() -> Parent ! {pmap, self(), F(E, Bucket, Fun)} end).

wait_result() ->
    receive
        {'EXIT', Reason} -> exit(Reason);
	    {pmap, _Pid,Result} -> Result
    end.