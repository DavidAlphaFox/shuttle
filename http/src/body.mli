open! Core
open! Async

(** [Stream] represents streaming HTTP bodies. This module provides utilities to create
    and consume streams, while enforcing the invariant that only one consume can read from
    a stream, and that a stream can only be consumed once. *)
module Stream : sig
  type t [@@deriving sexp_of]

  (** [of_pipe] is a convenience function that creates a stream from a user provided
      [Async_kernel.Pipe.Reader.t]. The pipe will be closed whenever the streaming body is
      closed, or EOF is reached. *)
  val of_pipe : [ `Chunked | `Fixed of int ] -> string Pipe.Reader.t -> t

  (** [close] allows for closing/tearing-down any resources that are used to produce the
      content for a stream. For servers, this function will be called if the underlying
      client socket connection is closed, or when the body is fully drained. *)
  val close : t -> unit

  (** [encoding] informs whether the body needs to be chunk encoded or not. For servers
      this function is used to automatically populate the transfer-encoding or
      content-length headers. *)
  val encoding : t -> [ `Chunked | `Fixed of int ]

  (** [iter t ~f] consumes chunks of data one at a time. The stream can only be iterated
      on once. *)
  val iter : t -> f:(string -> unit Deferred.t) -> unit Deferred.t

  (** [drain] should consume items one at a time from the stream and discard them. This
      function raises if its called after a consumer has started reading data from the
      stream. *)
  val drain : t -> unit Deferred.t

  (** [closed] is a deferred that should be resolved when the stream is closed/drained. *)
  val closed : t -> unit Deferred.t

  (** [read_started] indicated whether a user started to consume a stream or not. Servers
      will use [read_started] to verify if they should drain before starting the next
      cycle of the server loop, or if they should wait for the body to be closed by the
      user. *)
  val read_started : t -> bool
end

type t = private
  | Empty
  | Fixed of string
  | Stream of Stream.t
[@@deriving sexp_of]

(** [string str] creates a fixed length encoded body from a user provided string. *)
val string : string -> t

(** [empty] is a zero length body. *)
val empty : t

(** [of_pipe] is a convenience function that creates a streaming body from a user provided
    [Async_kernel.Pipe.Reader.t]. The pipe will be closed whenever the streaming body is
    closed, or EOF is reached. *)
val of_pipe : [ `Chunked | `Fixed of int ] -> string Pipe.Reader.t -> t

(** [stream] creates a streaming body from a user provided streaming module. *)
val stream : Stream.t -> t

(** [to_stream] converts a HTTP body to a stream. *)
val to_stream : t -> Stream.t
