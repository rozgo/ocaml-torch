open Base
open Torch

type state = Tensor.t

module Transition = struct
  type t =
    { state : state
    ; action : int
    ; next_state : state
    ; reward : float
    }

  let batch_states ts =
    List.map ts ~f:(fun t -> t.state)
    |> Tensor.stack ~dim:0

  let batch_next_states ts =
    List.map ts ~f:(fun t -> t.next_state)
    |> Tensor.stack ~dim:0

  let batch_rewards ts =
    List.map ts ~f:(fun t -> t.reward)
    |> Array.of_list
    |> Tensor.of_float1

  let batch_actions ts =
    List.map ts ~f:(fun t -> t.action)
    |> Array.of_list
    |> Tensor.of_int1
end

module Replay_memory : sig
  type _ t
  val create : capacity:int -> _ t
  val push : 'a t -> 'a -> unit
  val sample : 'a t -> batch_size:int -> 'a list
end = struct
  type 'a t =
    { memory : 'a Queue.t
    ; capacity : int
    ; mutable position : int
    }

  let create ~capacity =
    { memory = Queue.create ()
    ; capacity
    ; position = 0
    }

  let push t elem =
    if Queue.length t.memory < t.capacity
    then begin
      Queue.enqueue t.memory elem;
    end else begin
      Queue.set t.memory t.position elem
    end;
    t.position <- (t.position + 1) % t.capacity

  let sample t ~batch_size =
    List.init batch_size ~f:(fun _ ->
      let index = Random.int (Queue.length t.memory) in
      Queue.get t.memory index)
end

let linear_model vs ~input_dim actions_dim =
  let linear1 = Layer.linear vs ~input_dim 128 in
  let linear2 = Layer.linear vs ~input_dim:128 128 in
  let linear3 = Layer.linear vs ~input_dim:128 actions_dim in
  Layer.of_fn (fun xs ->
    Layer.apply linear1 xs
    |> Tensor.relu
    |> Layer.apply linear2
    |> Tensor.relu
    |> Layer.apply linear3)

let cnn_model vs =
  let conv2d = Layer.conv2d_ vs ~ksize:5 ~stride:2 in
  let conv1 = conv2d ~input_dim:3 16 in
  let bn1 = Layer.batch_norm2d vs 16 in
  let conv2 = conv2d ~input_dim:16 32 in
  let bn2 = Layer.batch_norm2d vs 32 in
  let conv3 = conv2d ~input_dim:32 32 in
  let bn3 = Layer.batch_norm2d vs 32 in
  let linear = Layer.linear vs ~input_dim:448 (* or 512 ? *) 2 in
  Layer.of_fn_ (fun xs ~is_training ->
    Layer.apply conv1 xs
    |> Layer.apply_ bn1 ~is_training
    |> Tensor.relu
    |> Layer.apply conv2
    |> Layer.apply_ bn2 ~is_training
    |> Tensor.relu
    |> Layer.apply conv3
    |> Layer.apply_ bn3 ~is_training
    |> Tensor.relu
    |> Tensor.flatten
    |> Layer.apply linear)

module DqnAgent : sig
  type t
  val create : state_dim:int -> actions:int -> memory_capacity:int -> t
  val action : t -> state -> int
  val learn : t -> unit
end = struct
  type t =
    { model : Layer.t
    ; memory : Transition.t Replay_memory.t
    ; actions : int
    ; batch_size : int
    ; gamma : float
    ; epsilon : float
    ; optimizer : Optimizer.t
    }

  let create ~state_dim ~actions ~memory_capacity =
    let vs = Var_store.create ~name:"dqn" () in
    let model = linear_model vs ~input_dim:state_dim actions in
    let memory = Replay_memory.create ~capacity:memory_capacity in
    let optimizer = Optimizer.adam vs ~learning_rate:1e-3 in
    { model
    ; memory
    ; actions
    ; batch_size = 128
    ; gamma = 0.99
    ; epsilon = 0.01
    ; optimizer
    }

  let action t state =
    (* epsilon-greedy action choice. *)
    if Float.(<) t.epsilon (Random.float 1.)
    then begin
      let qvalues =
        Tensor.no_grad (fun () ->
          Tensor.unsqueeze state ~dim:0
          |> Layer.apply t.model)
      in
      Tensor.argmax1 qvalues ~dim:1 ~keepdim:false
      |> Tensor.to_int1_exn
      |> fun xs -> xs.(0)
    end else Random.int t.actions

  let learn t =
    let transitions = Replay_memory.sample t.memory ~batch_size:t.batch_size in
    let states = Transition.batch_states transitions in
    let next_states = Transition.batch_next_states transitions in
    let actions = Transition.batch_actions transitions in
    let rewards = Transition.batch_rewards transitions in
    let qvalues =
      Layer.apply t.model states
      |> Tensor.gather ~dim:1 ~index:(Tensor.unsqueeze actions ~dim:1)
      |> Tensor.squeeze1 ~dim:1
    in
    let next_qvalues, _ =
      Layer.apply t.model next_states
      |> Tensor.max2 ~dim:1 ~keepdim:false
    in
    let expected_qvalues = Tensor.(rewards + f t.gamma * next_qvalues) in
    let loss = Tensor.mse_loss qvalues expected_qvalues in
    Optimizer.backward_step t.optimizer ~loss
end
