open! Core
open! Async

let rec connect path =
  match%bind
    Monitor.try_with (fun () -> Tcp.connect (Tcp.Where_to_connect.of_file path))
  with
  | Ok (_, r, w) -> return (r, w)
  | Error _ ->
    let%bind () = Clock_ns.after (Time_ns.Span.of_sec 0.01) in
    connect path
;;

let cleanup process =
  Process.send_signal process Signal.kill;
  let%bind (_ : Unix.Exit_or_signal.t) = Process.wait process in
  return ()
;;

let with_client path ~f =
  let%bind r, w = connect path in
  Monitor.protect
    (fun () -> f r w)
    ~finally:(fun () -> Writer.close w >>= fun () -> Reader.close r)
;;

let with_server path ~f =
  let%bind process = Process.create_exn ~prog:"./bin/http_server.exe" ~args:[ path ] () in
  Monitor.protect ~finally:(fun () -> cleanup process) (fun () -> f ())
;;

let with_server_custom_error_handler path ~f =
  let%bind process =
    Process.create_exn
      ~prog:"./bin/http_server_custom_error_handler.exe"
      ~args:[ path ]
      ()
  in
  Monitor.protect ~finally:(fun () -> cleanup process) (fun () -> f ())
;;
