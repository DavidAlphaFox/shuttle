open! Core
open! Async
open! Shuttle

type error_handler = ?exn:Exn.t -> ?request:Request.t -> Status.t -> Response.t Deferred.t
[@@deriving sexp_of]

let default_error_handler ?exn:_ ?request:_ status =
  return
    (Response.create
       ~headers:(Headers.of_rev_list [ "Connection", "close"; "Content-Length", "0" ])
       ~body:Body.empty
       status)
;;

type service = Request.t -> Response.t Deferred.t [@@deriving sexp_of]

type t =
  { closed : unit Ivar.t
  ; monitor : Monitor.t
  ; reader : Input_channel.t
  ; writer : Output_channel.t
  ; error_handler : error_handler
  ; read_header_timeout : Time_ns.Span.t
  }
[@@deriving sexp_of]

let closed t = Ivar.read t.closed
let close t = if Ivar.is_empty t.closed then Ivar.fill t.closed ()

let write_response t res =
  Output_channel.write t.writer (Version.to_string (Response.version res));
  Output_channel.write_char t.writer ' ';
  Output_channel.write t.writer (Status.to_string (Response.status res));
  Output_channel.write_char t.writer ' ';
  Output_channel.write t.writer "\r\n";
  let headers = Response.headers res in
  let headers, is_chunked =
    match Response.body res with
    | Body.Empty ->
      Headers.add_unless_exists headers ~key:"Content-Length" ~data:"0", false
    | Body.Fixed x ->
      ( Headers.add_unless_exists
          headers
          ~key:"Content-Length"
          ~data:(Int.to_string (String.length x))
      , false )
    | Body.Stream stream ->
      (* Schedule a close operation for the response stream, if for whatever reason the
         remote connection is torn down before the stream was driven to completion. This
         should ensure that any resource held by the stream will get cleaned up. *)
      upon (Output_channel.remote_closed t.writer) (fun () -> Body.Stream.close stream);
      (match Body.Stream.encoding stream with
       | `Chunked ->
         Headers.add_unless_exists headers ~key:"Transfer-Encoding" ~data:"chunked", true
       | `Fixed len ->
         ( Headers.add_unless_exists
             headers
             ~key:"Content-Length"
             ~data:(Int.to_string len)
         , false ))
  in
  Headers.iter
    ~f:(fun ~key ~data ->
      Output_channel.write t.writer key;
      Output_channel.write t.writer ": ";
      Output_channel.write t.writer data;
      Output_channel.write t.writer "\r\n")
    headers;
  Output_channel.write t.writer "\r\n";
  match Response.body res with
  | Body.Empty -> Output_channel.flush t.writer
  | Body.Fixed x ->
    Output_channel.write t.writer x;
    Output_channel.flush t.writer
  | Body.Stream stream ->
    let%bind () =
      Body.Stream.iter stream ~f:(fun v ->
        if String.is_empty v
        then Deferred.unit
        else if is_chunked
        then (
          Output_channel.writef t.writer "%x\r\n" (String.length v);
          Output_channel.write t.writer v;
          Output_channel.write t.writer "\r\n";
          Output_channel.flush t.writer)
        else (
          Output_channel.write t.writer v;
          Output_channel.flush t.writer))
    in
    if is_chunked
    then (
      Output_channel.write t.writer "0\r\n\r\n";
      Output_channel.flush t.writer)
    else Output_channel.flush t.writer
;;

let create
  ?(error_handler = default_error_handler)
  ?(read_header_timeout = Time_ns.Span.minute)
  reader
  writer
  =
  let t =
    { closed = Ivar.create ()
    ; monitor = Monitor.create ()
    ; reader
    ; writer
    ; error_handler
    ; read_header_timeout
    }
  in
  upon (Output_channel.remote_closed writer) (fun () -> Ivar.fill_if_empty t.closed ());
  t
;;

let keep_alive headers =
  match Headers.find headers "connection" with
  | Some x when String.Caseless.equal x "close" -> false
  | _ -> true
;;

let get_transfer_encoding headers =
  match List.rev @@ Headers.find_multi headers "Transfer-Encoding" with
  | x :: _ when String.Caseless.equal x "chunked" -> `Chunked
  | _x :: _ -> `Bad_request
  | [] ->
    (match
       List.dedup_and_sort
         ~compare:String.Caseless.compare
         (Headers.find_multi headers "Content-Length")
     with
     | [] -> `Fixed 0
     (* TODO: check for exceptions when converting to int *)
     | [ x ] ->
       let len =
         try Int.of_string x with
         | _ -> -1
       in
       if Int.(len >= 0) then `Fixed len else `Bad_request
     | _ -> `Bad_request)
;;

let parse_request_body t request =
  match get_transfer_encoding (Request.headers request) with
  | `Fixed 0 -> Ok Body.empty
  | `Fixed len ->
    let view = Input_channel.view t.reader in
    if view.len >= len
    then (
      let chunk = Bigstring.to_string view.buf ~pos:view.pos ~len in
      Input_channel.consume t.reader len;
      Ok (Body.string chunk))
    else (
      let pipe =
        Pipe.create_reader ~close_on_exception:false (fun writer ->
          Deferred.repeat_until_finished len (fun len ->
            let view = Input_channel.view t.reader in
            if view.len > 0
            then (
              let to_read = min len view.len in
              let chunk = Bigstring.to_string view.buf ~pos:view.pos ~len:to_read in
              Input_channel.consume t.reader to_read;
              let%map () = Pipe.write_if_open writer chunk in
              if to_read = len then `Finished () else `Repeat (len - to_read))
            else (
              match%map Input_channel.refill t.reader with
              | `Eof -> `Finished ()
              | `Ok -> `Repeat len)))
      in
      Ok (Body.of_pipe (`Fixed len) pipe))
  | `Chunked ->
    let pipe =
      Pipe.create_reader ~close_on_exception:false (fun writer ->
        Deferred.repeat_until_finished Parser.Start_chunk (fun state ->
          let view = Input_channel.view t.reader in
          match Parser.parse_chunk ~pos:view.pos ~len:view.len view.buf state with
          | Error Partial ->
            (match%map Input_channel.refill t.reader with
             | `Eof -> `Finished ()
             | `Ok -> `Repeat state)
          | Error (Fail error) -> Error.raise error
          | Ok (parse_result, consumed) ->
            Input_channel.consume t.reader consumed;
            (match parse_result with
             | Parser.Chunk_complete chunk ->
               let%map () = Pipe.write_if_open writer chunk in
               `Repeat Parser.Start_chunk
             | Parser.Done -> return (`Finished ())
             | Parser.Partial_chunk (chunk, to_consume) ->
               let%map () = Pipe.write_if_open writer chunk in
               `Repeat (Parser.Continue_chunk to_consume))))
    in
    Ok (Body.of_pipe `Chunked pipe)
  | `Bad_request -> Or_error.error_s [%sexp "Invalid transfer encoding"]
;;

let run t handler =
  let rec parse_request t =
    let view = Input_channel.view t.reader in
    match Parser.parse_request view.buf ~pos:view.pos ~len:view.len with
    | Error Partial ->
      Input_channel.refill t.reader
      >>> (function
      | `Eof -> Ivar.fill t.closed ()
      | `Ok -> parse_request t)
    | Error (Fail error) ->
      t.error_handler ~exn:(Error.to_exn error) `Bad_request
      >>> fun response -> write_response t response >>> fun () -> Ivar.fill t.closed ()
    | Ok (req, consumed) ->
      Input_channel.consume t.reader consumed;
      create_request_body_reader t req
  and parse_request_with_timeout t span =
    let view = Input_channel.view t.reader in
    match Parser.parse_request view.buf ~pos:view.pos ~len:view.len with
    | Error Partial ->
      let now = Time_ns.now () in
      Input_channel.refill_with_timeout t.reader span
      >>> fun v ->
      (match v with
       | `Eof -> Ivar.fill t.closed ()
       | `Ok ->
         let now' = Time_ns.now () in
         let diff = Time_ns.abs_diff now now' in
         parse_request_with_timeout t Time_ns.Span.(span - diff))
    | Error (Fail error) ->
      t.error_handler ~exn:(Error.to_exn error) `Bad_request
      >>> fun response -> write_response t response >>> fun () -> Ivar.fill t.closed ()
    | Ok (req, consumed) ->
      Input_channel.consume t.reader consumed;
      create_request_body_reader t req
  and create_request_body_reader t req =
    match parse_request_body t req with
    | Error e ->
      t.error_handler ~exn:(Error.to_exn e) ~request:req `Bad_request
      >>> fun response -> write_response t response >>> fun () -> Ivar.fill t.closed ()
    | Ok req_body ->
      let req = Request.with_body req req_body in
      let promise = handler req in
      if Deferred.is_determined promise
      then write_response_and_continue t req (Deferred.value_exn promise)
      else promise >>> fun response -> write_response_and_continue t req response
  and write_response_and_continue t req response =
    let is_keep_alive =
      keep_alive (Request.headers req) && keep_alive (Response.headers response)
    in
    write_response t response
    >>> fun () ->
    if is_keep_alive
    then (
      match Request.body req with
      | Body.Empty | Body.Fixed _ ->
        if Time_ns.Span.is_positive t.read_header_timeout
        then parse_request_with_timeout t t.read_header_timeout
        else parse_request t
      | Body.Stream stream ->
        (if Body.Stream.read_started stream
        then Body.Stream.closed stream
        else Body.Stream.drain stream)
        >>> fun () ->
        if Time_ns.Span.is_positive t.read_header_timeout
        then parse_request_with_timeout t t.read_header_timeout
        else parse_request t)
    else Ivar.fill t.closed ()
  in
  Monitor.detach t.monitor;
  Scheduler.within ~priority:Priority.normal ~monitor:t.monitor (fun () ->
    if Time_ns.Span.is_positive t.read_header_timeout
    then parse_request_with_timeout t t.read_header_timeout
    else parse_request t);
  upon (Monitor.get_next_error t.monitor) (fun exn ->
    (match Monitor.extract_exn exn with
     | Input_channel.Timeout -> t.error_handler `Request_timeout
     | exn -> t.error_handler ~exn `Internal_server_error)
    >>> fun response ->
    if Ivar.is_empty t.closed
    then write_response t response >>> fun () -> Ivar.fill t.closed ());
  Ivar.read t.closed
;;
