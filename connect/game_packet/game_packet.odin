package game_package

import "core:encoding/cbor"
import "core:net"
import sa "core:container/small_array"
import "base:runtime"
import "core:time"
import "core:fmt"
import "core:strings"
import "core:slice"
import rl "vendor:raylib"

SEQUENCE_BUFFER_SIZE :: 1024
MAX_CONNECTIONS :: 4

buf: [4096]byte

Network :: struct {
    host_id: int,
    this_id: i8,
    color: Color,
    socket: net.UDP_Socket,
    channels: sa.Small_Array(MAX_CONNECTIONS, Channel) `fmt:"-"`,
    net_allocator: runtime.Allocator,
    net_temp: runtime.Allocator,
    msg_allocator: runtime.Allocator,
    msg_temp: runtime.Allocator,
    msg_delete_proc: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator),
    msg_clone_proc: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator) -> Message,
    message_queue: [dynamic]Message,
    last_tick: time.Tick,
    tick_accum: time.Duration,

    // Snapshot stuff
    using snap_state : struct {
        snap_color: Color,
        is_recording: bool,
        snap_ready: bool,
        should_snapshot: bool,
        recorded_count: int,

        // Needed for resending partial snaps
        partial_compiled: bool,
        partial_snap: Partial_Snapshot,
    },

    // Game save stuff
    using save_state : struct {
        snapshots_received: bit_set[1..=MAX_CONNECTIONS; u8],
        is_saving: bool,
        partial_count: int,
        game_save: Game_Save,
    },

    // Load Save stuff
    using load_state : struct {
        is_loaded: bool,
        partial_received: bool,
        partial_save: Partial_Save,
    }
}

Game_Save :: struct {
    is_complete: bool,
    partials: []Partial_Save,
}

default_delete_proc :: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator) {
    switch v in message {
        case int:
        case []int:
            delete(v)
        case Player_Move, Placed_Fence, Attack_Fence, Attack_Player, Dead_Player, Player_Start, Request_Fences:
        case Send_Fences:
            delete(v.fences, allocator)
    }
}

default_clone_proc :: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator) -> Message {
    switch v in message {
        case int:
            return v
        case []int:
            return slice.clone(v)
        case Player_Move, Placed_Fence, Attack_Fence, Attack_Player, Dead_Player, Player_Start, Request_Fences:
            return v
        case Send_Fences:
            return Send_Fences{
                fences = slice.clone(v.fences, allocator)
            }
    }
    return nil
}

delete_message :: proc(network: ^Network, message: Message) {
    network.msg_delete_proc(message, network.msg_allocator, network.msg_temp)
}

clone_message :: proc(network: ^Network, message: Message) -> Message {
    return network.msg_clone_proc(message, network.msg_allocator, network.msg_temp)
}

Channel :: struct {
    endpoint: net.Endpoint,

    // Header things
    id: i8,
    seq: u16,
    ack: u16,
    ack_processed: u16,
    prev_end_seq: u16,

    // Buffer shenanigans
    seq_send: Sequence_Buffer `fmt:"-"`, 
    buf_recv: [SEQUENCE_BUFFER_SIZE]u32 `fmt:"-"`,
    unprocessed: [dynamic]Message `fmt:"-"`,

    // Snapshot stuff
    using snap_state : struct {
        marker_received: bool,
        done_recording: bool,
    },

    // Recording stuff
    using record_state: struct {
        record_end_seq: u16,
        record_start_seq: u16,
        recorded_messages: [dynamic]Message,
    }
}

Sequence_Buffer :: struct {
    buf_seq: [SEQUENCE_BUFFER_SIZE]u32,
    buf_col: [SEQUENCE_BUFFER_SIZE]Color,
    buf_msg: []Message,
}

@private
init_sequence_buffer :: proc(network: ^Network, sbuffer: ^Sequence_Buffer)  {
    for &sequence in sbuffer.buf_seq{
        sequence = max(u32)
    }
    sbuffer.buf_msg = make([]Message, SEQUENCE_BUFFER_SIZE, network.net_allocator)
}

@private
delete_sequence_buffer :: proc(network: ^Network, sbuffer: ^Sequence_Buffer) {
    for &sequence, i in sbuffer.buf_seq{
        if sequence != max(u32) {
            delete_message(network, sbuffer.buf_msg[i])
        }
    }
    delete(sbuffer.buf_msg, network.net_allocator)
}

@private
get_ack_bits :: proc(buf_recv: [SEQUENCE_BUFFER_SIZE]u32, ack: u16) -> bit_set[1..=32; u32] {
    out: bit_set[1..=32; u32]
    for n in 1..=u16(32) {
        // ack = 0, prev_sequence = 65,535
        ack_minus_n := ack - n

        // prev_seq = 65,535, index = 1023
        index := ack_minus_n % SEQUENCE_BUFFER_SIZE

        // if sbuffer[1023] == 65,535 -> this has been seen before
        if buf_recv[index] == u32(ack_minus_n) { 

            // I now know that sequence u16(0 - 1) was received by this client (seq - n)
            // if the nth bit is set, then ack - n was acked by this client
            out += {int(n)}
        }
    }
    return out
}


@private
get_data :: proc(network: ^Network, sbuffer: ^Sequence_Buffer, sequence: u16) -> (^Message, Color) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    if sbuffer.buf_seq[index] == u32(sequence) {
        return &sbuffer.buf_msg[index], sbuffer.buf_col[index]
    } else {
        return nil, .None
    }
}

@private
put_message:: proc(network: ^Network, sbuffer: ^Sequence_Buffer, message: Message, sequence: u16, color: Color) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    old_data: Data 

    if sbuffer.buf_seq[index] != max(u32) {
        // get the old data
        old_data = sbuffer.buf_msg[index]

        // since its getting replaced we can delete it
        delete_message(network, sbuffer.buf_msg[index])
    }

    // set new sequence number
    sbuffer.buf_seq[index] = u32(sequence)

    // set color of message
    sbuffer.buf_col[index] = color

    // set new data
    sbuffer.buf_msg[index] = message
}

@private
put_buf_recv :: proc(buf_recv: ^[SEQUENCE_BUFFER_SIZE]u32, sequence: u16) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    buf_recv[index] = u32(sequence)
}

@private
acknowledge :: proc(network: ^Network, sbuffer: ^Sequence_Buffer, sequence: u16) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    if sbuffer.buf_seq[index] != max(u32) {
        acked_data := sbuffer.buf_msg[index]
        delete_message(network, acked_data)
        sbuffer.buf_seq[index] = max(u32)
    }
}

Color :: enum u8 {
    None,
    White,
    Red,
    Blue,
}

@(private)
Header :: struct #packed {
    color: Color,
    from: i8,
    seq: u16,
    ack: u16,
    ack_processed: u16,
    prev_end_seq: u16,
    save_bits: bit_set[1..=MAX_CONNECTIONS; u8],
    ack_bits: bit_set[1..=32; u32],
}

Keep_Alive :: struct {}
Marker :: struct {}
Partial_Snapshot :: struct {
    state: []byte,
    msgs: []byte,
}

Partial_Save :: struct {
    state: []byte,
    msgs: []byte,
}

Internal :: union {
    Keep_Alive,
    Marker,
    Partial_Snapshot,
    Partial_Save,
}

Message :: union {
    int,
    string,
    []int,
    Player_Move,
    Placed_Fence,
    Attack_Fence,
    Attack_Player,
    Dead_Player,
    Player_Start,
    Send_Fences,
    Request_Fences
}

Data :: union #shared_nil {
    Internal,
    Message,
}

Packet :: struct {
    header: Header,
    data: Data,
}

Player_Move :: struct {
    src: rl.Rectangle,
    dest: rl.Rectangle,
    color: rl.Color,
    id: i64,
    attacking: bool,
    placing_fence: bool,
    direction: i32,
    health: i32
}

Fence :: struct {
    dest: rl.Rectangle,
    health: int,
    id: [2]int
}

Placed_Fence :: struct {
    dest: rl.Rectangle,
    id: [2]int
}

Attack_Fence :: struct {
    id: [2]int,
    health: int,
    destroyed: bool
}

Attack_Player :: struct {
    id: i64
}

Dead_Player :: struct {
    id: i64
}

Player_Start :: struct {
    id: i64
}

Request_Fences :: struct {
    id: i64
}

Send_Fences :: struct {
    fences: []Fence
}

init_network :: proc(
    network: ^Network,
    socket: net.UDP_Socket,
    host_endpoint: net.Endpoint,
    msg_delete_proc: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator),
    msg_clone_proc: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator) -> Message,
    this_process := false,
    expect_save := false,
    msg_allocator := context.allocator,
    msg_temp := context.allocator,
    net_allocator := context.allocator,
    net_temp:= context.temp_allocator,
) -> (host_id: int, ok: bool) { 
    if network.net_allocator != {} {
        return
    }
    fmt.println("INITING NETWORK")

    // allocators first
    network.net_allocator = net_allocator
    network.net_temp = net_temp
    network.msg_allocator = msg_allocator
    network.msg_temp = msg_temp

    host_id = add_connection(network, host_endpoint) or_return
    network.host_id = host_id
    network.color = .White
    network.socket = socket
    network.msg_delete_proc = msg_delete_proc
    network.msg_clone_proc = msg_clone_proc
    network.message_queue = make([dynamic]Message, net_allocator)

    // Partial Snapshot stuffs
    network.snap_state = {}

    // GAme Save stuffs
    network.save_state = {}
 
    // Loading stuffs
    network.load_state = {
        is_loaded = !expect_save,
        partial_save = {},
    }
    return
}

close_network :: proc(network: ^Network) {
    for &channel in sa.slice(&network.channels) {
        delete_channel(network, &channel)
    }
    cleanup_messages(network)
    delete(network.message_queue)
}

load_network :: proc(
    network: ^Network, 
    save_state: ^$T, 
    bytes: []byte, 
    allocator := context.allocator, 
    temp_allocator := context.temp_allocator
) -> (
    messages: []Message, 
    err: cbor.Unmarshal_Error) {

    assert(this_is_host(network^))
    assert(!network.is_loaded)

    // OPEN THE GATES
    start_network(network)
    game_save: Game_Save
    cbor.unmarshal_from_string(transmute(string)bytes, &game_save, {}, network.msg_allocator, network.msg_temp) or_return
    assert(game_save.is_complete)
    assert(len(game_save.partials) == sa.len(network.channels))

    host_partial := game_save.partials[network.host_id]
    msgs: [][]Message
    cbor.unmarshal_from_string(transmute(string)host_partial.state, save_state, {}, allocator, temp_allocator) or_return
    cbor.unmarshal_from_string(transmute(string)host_partial.msgs, &msgs, {}, network.msg_allocator, network.msg_temp) or_return

    for &c in sa.slice(&network.channels) {
        if int(c.id) == network.host_id {
            continue
        }
        partial := game_save.partials[c.id]
        send_data_to_channel(network, Internal(partial), &c)
    }

    // Make a single array of all the saved messages
    compiled_messages := make([dynamic]Message, network.net_allocator)
    for channel_messages in msgs {
        for message in channel_messages {
            if message != nil {
                append(&compiled_messages, message)
            }
        }
        // the slice is deleted but any memory allocated in the messages will still exist
        delete(channel_messages, network.msg_allocator)
    }
    delete(msgs, network.msg_allocator)
    messages = slice.clone(compiled_messages[:], network.msg_allocator)
    delete(compiled_messages)

    // Delete Game Save
    for partial in game_save.partials {
        delete(partial.state, network.msg_allocator)
        delete(partial.msgs, network.msg_allocator)
    }
    delete(game_save.partials, network.msg_allocator)

    network.is_loaded = true
    return 
}

wait_for_load_save :: proc(
    network: ^Network, 
    save_state: ^$T,
    allocator := context.allocator,
    temp_allocator := context.temp_allocator
) -> (
    messages: []Message, 
    err: cbor.Unmarshal_Error
) {
    // OPEN THE GATES
    start_network(network)

    // Wait for the partial to be received
    // Other relevant messages will be gathered up in their respective channel buffer so this is fine
    for !network.partial_received {
        poll_for_packets(network)
    }

    // retrieve our partial save from the network
    partial := network.partial_save

    // Load the saved state
    cbor.unmarshal_from_string(transmute(string)partial.state, save_state, {}, allocator, temp_allocator) or_return

    // Load the list of messages for each channel
    msgs: [][]Message
    cbor.unmarshal_from_string(transmute(string)partial.msgs, &msgs, {}, network.msg_allocator, network.msg_temp) or_return
    assert(len(msgs) == sa.len(network.channels))

    // Make a single array of all the saved messages
    compiled_messages := make([dynamic]Message, network.net_allocator)
    for channel_messages in msgs {
        for message in channel_messages {
            if message != nil {
                append(&compiled_messages, message)
            }
        }
        // the slice is deleted but any memory allocated in the messages will still exist
        delete(channel_messages, network.msg_allocator)
    }
    delete(msgs, network.msg_allocator)
    messages = slice.clone(compiled_messages[:], network.msg_allocator)
    delete(compiled_messages)

    delete(partial.state, network.msg_allocator)
    delete(partial.msgs, network.msg_allocator)
    network.is_loaded = true
    return
}

cleanup_loaded_messages :: proc(network: ^Network, messages: []Message) {
    for message in messages {
        delete_message(network, message)
    }
    delete(messages, network.msg_allocator)
}

start_network :: proc(network: ^Network) {
    network.last_tick = time.tick_now()
    broadcast_data(network, Internal(Keep_Alive{}))
}

add_connection :: proc(network: ^Network, endpoint: net.Endpoint, this_process := false) -> (channel_id: int, ok: bool) {
    if network.net_allocator == {} {
        return
    }

    new_id := network.channels.len
    new_channel := Channel{
        id = i8(new_id),
        endpoint = endpoint,
        seq = max(u16), // 0xFFFF
        ack = max(u16),
        ack_processed = max(u16), // 0xFFFF
        prev_end_seq = max(u16),
        unprocessed = make([dynamic]Message, network.net_allocator),
        recorded_messages = make([dynamic]Message, network.net_allocator),
    }

    if this_process {
        network.this_id = i8(new_id)
    }

    init_sequence_buffer(network, &new_channel.seq_send) 

    for &sequence in new_channel.buf_recv {
        sequence = max(u32)
    }
    sa.push_back(&network.channels, new_channel) or_return
    network.snapshots_received += {int(new_id + 1)}
    return new_id, true
}

@private
delete_channel :: proc(network: ^Network, channel: ^Channel) {
    delete_sequence_buffer(network, &channel.seq_send)
    for message in channel.unprocessed {
        if message != nil {
            delete_message(network, message)
        }
    }
    delete(channel.unprocessed)
    delete(channel.recorded_messages)
}

@private
broadcast_data :: proc(network: ^Network, data: Data) -> bool {
    for &channel in sa.slice(&network.channels) {
        udp_err := send_data_to_channel(network, data, &channel)
        if udp_err != nil {
            return false
        }    
    }
    return true
}

@private
send_data:: proc(network: ^Network, data: Data, net_id: int) -> bool {
    if net_id >= MAX_CONNECTIONS {
        return false
    }
    udp_err := send_data_to_channel(network, data, sa.get_ptr(&network.channels, net_id))
    if udp_err != nil {
        return false
    }
    return true
}

send_message :: proc(network: ^Network, message: Message, net_id: int) -> bool {
    return send_data(network, clone_message(network, message), net_id) 
}

broadcast_message :: proc(network: ^Network, message: Message) -> bool {
    for &channel in sa.slice(&network.channels) {
        udp_err := send_data_to_channel(network, clone_message(network, message), &channel)
        if udp_err != nil {
            return false
        }    
    }
    return true
}

@private
send_data_to_channel :: proc(network: ^Network, data: Data, channel: ^Channel) -> net.UDP_Send_Error { 
    packet: Packet
    packet.header.from = network.this_id
    packet.header.color = network.color
    packet.header.ack = channel.ack
    packet.header.ack_processed = channel.ack_processed
    packet.header.save_bits = network.snapshots_received
    packet.header.ack_bits = get_ack_bits(channel.buf_recv, channel.ack)
    packet.header.prev_end_seq = channel.prev_end_seq
    packet.data = data 

    // only increment the sequence number if we're sending a message, this is CRUCIAL
    if message, ok := data.(Message); ok {
        channel.seq += 1
        put_message(network, &channel.seq_send, message, channel.seq, network.color)
    }
    packet.header.seq = channel.seq

    // rand := rand.float32()
    // if rand < 0.5 {
    //     return nil
    // }

    bytes, marshal_err := cbor.marshal_into_bytes(packet, cbor.ENCODE_SMALL, network.net_allocator, network.net_temp)
    defer delete(bytes)

    net.send_udp(network.socket, bytes, channel.endpoint) or_return
    return nil
}

poll_for_packets :: proc(network: ^Network)  { 
    time_now := time.tick_now()
    dt := time.tick_diff(network.last_tick, time_now)
    network.last_tick = time_now
    network.tick_accum += dt

    if network.tick_accum > time.Second/2 {
        network.tick_accum = 0
        broadcast_data(network, Internal(Keep_Alive{}))
    }

    for {
        bytes_read, _, recv_err := net.recv_udp(network.socket, buf[:])
        if bytes_read <= 0{
            break
        }
        packet: Packet
        cbor.unmarshal(transmute(string)buf[:bytes_read], &packet, {}, network.msg_allocator, network.msg_temp)
        deal_with_packet(network, packet)
    }

    // This means we've finished recording, and the partial snapshot is good to go
    if network.is_recording && network.recorded_count == sa.len(network.channels) {
        network.snap_state = {}
        network.snap_ready = true 

        // reset all the channels, still keep the recorded messages though
        for &c in sa.slice(&network.channels) {
            c.snap_state = {}
            c.record_state = {
                record_start_seq = 0,
                record_end_seq = 0,
                recorded_messages = c.recorded_messages
            }
        }
    }
}

should_snapshot :: proc(network: Network) -> bool {
    return network.should_snapshot
}

partial_snapshot_ready :: proc(network: Network) -> bool {
    return network.snap_ready
}

this_is_host :: proc(network: Network) -> bool {
    return int(network.this_id) == network.host_id
}

get_id :: proc(network: Network) -> int {
    return int(network.this_id)
}

game_save_start :: proc(network: ^Network) -> bool {
    assert(this_is_host(network^))
    if network.is_recording || // must not be already recording a snapshot
        network.snap_ready || // must have processed the previous snapshot
        network.is_saving { // must currently holding onto a save that hasn't been retrieved by client
        return false
    }

    // The host has to manage both saving their partial state and
    // compiling the partial states into a complete save

    network.save_state = { // game_save.partials is the same size as the number of processes (including itself)
        snapshots_received = {},
        is_saving = true,
        partial_count = 0,
        game_save = {
            is_complete = false,
            partials = make([]Partial_Save, sa.len(network.channels)),
        }
    }

    network.snap_state = { // Start recording stuff, indicate to the user that they should snapshot
        is_recording = true,
        should_snapshot = true,
        snap_ready = false,
        recorded_count = 0,
    }

    // Change network color and start recording on the channel
    network.color = next_color(network.color)
    for &c in sa.slice(&network.channels) {
        c.snap_state = {}
        c.record_state = {
            record_start_seq = c.ack_processed,
            record_end_seq = c.ack,
            recorded_messages = c.recorded_messages
        }
        c.prev_end_seq = c.seq

        for message in c.unprocessed {
            clone := clone_message(network, message)
            append(&c.recorded_messages, clone)
        }
    }
    return true
}

game_save_is_complete :: proc(network: Network) -> bool {
    assert(this_is_host(network))
    return network.game_save.is_complete
}

game_save_complete :: proc(network: ^Network) -> Game_Save {
    assert(this_is_host(network^))
    if network.game_save.is_complete {
        out := network.game_save
        network.save_state = {
            snapshots_received = network.snapshots_received
        }
        fmt.println("COMPLETE")
        return out
    }
    return {}
}

delete_game_save :: proc(network: ^Network, game_save: Game_Save) {
    assert(this_is_host(network^))
    for partial in game_save.partials {
        delete(partial.state, network.msg_allocator)
        delete(partial.msgs, network.msg_allocator)
    }
    delete(game_save.partials, network.net_allocator)
}

take_state_snapshot :: proc(network: ^Network, data: ^$T, $snapshot_proc: proc(^T) -> T) -> T {  
    assert(network.should_snapshot)
    network.should_snapshot = false
    return snapshot_proc(data)
}

partial_snapshot_create_and_send :: proc(network: ^Network, data: $T) {
    if network.snap_ready {

        // Should not be able to create partial snapshot twice
        network.snap_ready = false

        // Partial is compiled
        network.partial_compiled = true

        // Save State
        state_bytes, state_err := cbor.marshal_into_bytes(data, cbor.ENCODE_SMALL, network.msg_allocator, network.net_temp)

        // Save Messages
        msgs := make([][]Message, sa.len(network.channels), network.net_allocator)
        defer delete(msgs, network.net_allocator)
        for &c in sa.slice(&network.channels) {
            msgs[c.id] = c.recorded_messages[:]
        }
        msgs_bytes, msgs_err := cbor.marshal_into_bytes(msgs, cbor.ENCODE_SMALL, network.net_allocator, network.net_temp)

        // delete recorded messages
        for &c in sa.slice(&network.channels) {
            for message in c.recorded_messages {
                delete_message(network, message)
            }
            delete(c.recorded_messages)
            c.recorded_messages = make([dynamic]Message, network.net_allocator)
        }

        network.partial_snap = Partial_Snapshot{state_bytes, msgs_bytes}
        send_data(network, Internal(network.partial_snap), network.host_id)
    }
}

get_messages :: proc(network: ^Network) -> []Message {
    for &channel in sa.slice(&network.channels) {
        for message in channel.unprocessed {
            channel.ack_processed += 1
            if message != nil {
                append(&network.message_queue, message)
            }
        }
        clear(&channel.unprocessed)
    }
    return network.message_queue[:]
}

cleanup_messages :: proc(network: ^Network) {
    for message in network.message_queue {
        delete_message(network, message)
    }
    clear(&network.message_queue)
}

@private
resend_data_to_channel :: proc(network: ^Network, channel: ^Channel, data: Data, sequence: u16, color: Color) -> net.UDP_Send_Error {
    // fmt.printfln("resending %v", sequence)
    packet: Packet
    packet.header.from = network.this_id
    packet.header.color = color
    packet.header.seq = sequence
    packet.header.ack = channel.ack
    packet.header.ack_processed = channel.ack_processed
    packet.header.save_bits = network.snapshots_received
    packet.header.ack_bits = get_ack_bits(channel.buf_recv, channel.ack)
    packet.data = data 

    bytes, marshal_err := cbor.marshal_into_bytes(packet, cbor.ENCODE_SMALL, network.net_allocator, network.net_temp)
    defer delete(bytes)

    net.send_udp(network.socket, bytes, channel.endpoint) or_return
    return nil
}

// PAWS == Protect Against Wrap Around
// a greater than b
paws_greater_than :: proc(a, b: u16) -> bool {
    HALF_RANGE :: u16(1 << 15)
    diff := a - b
    return diff > 0 && diff < HALF_RANGE 
}

paws_less_or_eq :: proc(a, b: u16) -> bool {
    return !paws_greater_than(a, b)
}

@(private)
deal_with_message :: proc(network: ^Network, channel: ^Channel, message: Message, header: Header) {
    packet_seq := header.seq
    packet_ack := header.ack

    // Snapshot recording logic
    if network.is_recording && !channel.done_recording {
        if channel.marker_received && network.snap_color == header.color {
            // Only insert the message into the recording buffer if our main stream is was able to
            if paws_greater_than(packet_seq, channel.ack_processed) &&
                paws_less_or_eq(packet_seq, channel.record_end_seq) { // this is implicitly true since by definition of what channel.record_end_seq is after the marker is received
                index := packet_seq - channel.record_start_seq - 1
                if channel.recorded_messages[index] == nil {
                    clone := clone_message(network, message)
                    channel.recorded_messages[index] = clone
                }
            }

        } else if !channel.marker_received { // cannot have !channel.marker_received and header.color != snap_color
            if paws_greater_than(packet_seq, channel.record_end_seq) {

                // Fill out recording buffer
                for _ in 0..<(packet_seq - channel.record_end_seq - 1) {
                    append(&channel.recorded_messages, nil)
                }

                // Clone message so memory management is easier
                clone := clone_message(network, message)
                append(&channel.recorded_messages, clone)

                // Set record_end_seq to the most recent packet received that ISNT a new color
                channel.record_end_seq = packet_seq
            } else if paws_greater_than(packet_seq, channel.ack_processed) {
                index := packet_seq - channel.record_start_seq - 1
                if channel.recorded_messages[index] == nil {
                    clone := clone_message(network, message)
                    channel.recorded_messages[index] = clone
                }
            }
        }
    }

    // Otherwise proceed as normal
    if paws_greater_than(packet_seq, channel.ack) {
        put_buf_recv(&channel.buf_recv, packet_seq)
        for _ in 0..<(packet_seq - channel.ack - 1) {
            append(&channel.unprocessed, nil)
        }
        append(&channel.unprocessed, message)
        channel.ack = packet_seq
    } else if paws_greater_than(packet_seq, channel.ack_processed) {
        put_buf_recv(&channel.buf_recv, packet_seq)
        index := packet_seq - channel.ack_processed - 1
        if channel.unprocessed[index] == nil {
            channel.unprocessed[index] = message
        } else {
            delete_message(network, message)
        }
    } else {
        delete_message(network, message)
    }
}

@private
deal_with_internal :: proc(network: ^Network, channel: ^Channel, internal: Internal, header: Header) {
    packet_seq := header.seq
    packet_ack := header.ack
    packet_ack_processed := header.ack_processed
    packet_ack_bits := header.ack_bits

    switch v in internal {
        case Partial_Snapshot:

            fmt.println(header.from, network.snapshots_received, network.game_save.is_complete)

            // Should only appear on the host client
            assert(this_is_host(network^))

            // If we don't insert the snapshot, it means we've already received it before
            // just delete the message
            inserted := false
            defer if !inserted {
                delete(v.state, network.msg_allocator)
                delete(v.msgs, network.msg_allocator)
            }

            // Either haven't started a save or finished one
            if !network.is_saving || network.game_save.is_complete {
                break
            }

            // Check if we haven't already been sent this packet
            partial_save := &network.game_save.partials[header.from]
            if int(header.from + 1) not_in network.snapshots_received {
                inserted = true
                network.snapshots_received += {int(header.from + 1)}
                network.partial_count += 1
                network.game_save.partials[header.from] = {v.state, v.msgs}
            }

            if network.partial_count == sa.len(network.channels) {
                network.game_save.is_complete = true
            }

        case Partial_Save:
            if network.partial_received || network.is_loaded {
                delete(v.state, network.msg_allocator)
                delete(v.msgs, network.msg_allocator)
                break
            }
            network.partial_save = v

        case Keep_Alive:
        case Marker:
    }

    // fmt.printfln("%#v", header)
    if network.is_recording && !channel.marker_received {
        if paws_greater_than(packet_seq, channel.record_end_seq) {
            for _ in 0..<(packet_seq - channel.record_end_seq) {
                append(&channel.recorded_messages, nil)
            }
            channel.record_end_seq = packet_seq
        }
    }

    if paws_greater_than(packet_seq, channel.ack) {
        for _ in 0..<(packet_seq - channel.ack) {
            append(&channel.unprocessed, nil)
        }
        channel.ack = packet_seq
    }
}

@private
next_color :: proc(color: Color) -> Color {
    switch color {
        case .White:
            return .Red
        case .Red:
            return .Blue
        case .Blue:
            return .White
        case .None:
            return .None
    }
    return .None
}

@private
first_marker :: proc(network: ^Network, channel: ^Channel, header: Header) {

    // This should never be the case for the host
    assert(!this_is_host(network^))

    // Save color of current process, change process color and start recording messages
    network.is_recording = true
    network.snap_color = network.color
    network.color = next_color(network.color)
    network.partial_compiled = false

    // We need to tell the client to snapshot directly after this marker (or atleast after polling messages)
    network.should_snapshot = true

    // Pretty self explanatory
    channel.marker_received = true

    // Channel records messages that haven't been processed up till the end_sequence number 
    // indicated by the header of a different coloured message (THIS IS OUR MARKER PIGGYBACKING)
    channel.record_end_seq = header.prev_end_seq
    channel.record_start_seq = channel.ack_processed

    // Last sequence number that the receiver of our messages on this channel should include in their 
    // snapshot (THIS IS OUR MARKER PIGGYBACKING)
    channel.prev_end_seq = channel.seq

    // Copy all existing unprocessed messages to the recording buffer
    // this should be messages from [channel.ack_processed + 1, channel.ack]
    for message in channel.unprocessed {  
        clone := clone_message(network, message)
        append(&channel.recorded_messages, clone)
    }

    // if header.prev_end_seq happens to be larger than channel.ack (and not equal to), fill out the rest of the buffer 
    // Channel.record_end_seq can only be greater than or equal to the channel ack by definition
    // if channel.ack == 5 and chanel.record_end_seq == 6 then [1,2,3,nil,5] turns into [1,2,3,nil,5,nil]
    if paws_greater_than(channel.record_end_seq, channel.ack) {
        for _ in 0..<(channel.record_end_seq - channel.ack) {
            append(&channel.recorded_messages, nil)
        }
    }

    // For the other channels, we try to initialise the recording buffer with all the unprocessed packets
    for &c in sa.slice(&network.channels) {
        if c.id != channel.id {
            c.snap_state = {
                marker_received = false,
                done_recording = false,
            }
            c.record_state = {
                record_start_seq = c.ack_processed,
                record_end_seq = c.ack, // since we don't know what the marker is we will tie it to the channel.ack
            }

            c.prev_end_seq = c.seq
            for message in c.unprocessed {
                clone := clone_message(network, message)
                append(&c.recorded_messages, clone)
            }
        }
    }

    // broadcast the marker message with using the networks new color
    broadcast_data(network, Internal(Marker{}))
}

another_marker :: proc(network: ^Network, channel: ^Channel, header: Header) {
    channel.marker_received = true
    if paws_greater_than(header.prev_end_seq, channel.record_end_seq) {
        for _ in 0..<(header.prev_end_seq - channel.record_end_seq) {
            append(&channel.recorded_messages, nil)
        }
    }
    channel.record_end_seq = header.prev_end_seq
}

@private
deal_with_packet :: proc(network: ^Network, packet: Packet) {
    channel := sa.get_ptr(&network.channels, int(packet.header.from))
    header := packet.header

    // Is this the first time I've seen a different color to the current process color
    // Only true when we're not recording
    is_first_marker_received := !network.is_recording && network.color != header.color

    // Is this the first time I've seen a same colored message during the snapshot recording on this channel
    // Only true when we're recording
    another_marker_received := network.is_recording && !channel.marker_received && network.color == header.color

    // Check for snapshot conditions
    if is_first_marker_received {
        first_marker(network, channel, header) // essentially sets network.is_recording = true
    } else if another_marker_received {
        another_marker(network, channel, header) // essentially sets channel.marker_received = true
    }

    switch v in packet.data {
        case Internal:
            deal_with_internal(network, channel, v, header)
        case Message:
            deal_with_message(network, channel, v, header)
    }

    if network.is_recording && 
        channel.marker_received &&
        !channel.done_recording && 
        paws_greater_than(channel.ack_processed, channel.record_end_seq) {
        channel.done_recording = true
        network.recorded_count += 1 
    } // essentially sets channel.done_recording = true

    if int(header.from) == network.host_id &&
        network.partial_compiled {
        if int(network.this_id + 1) in header.save_bits {
            network.partial_compiled = false
            delete(network.partial_snap.state, network.net_allocator)
            delete(network.partial_snap.msgs, network.net_allocator)
        } else {
            send_data(network, Internal(network.partial_snap), network.host_id)
        }
    }

    // No longer concerned with the snapshot stuff
    packet_ack := header.ack
    packet_ack_processed := header.ack_processed
    packet_ack_bits := header.ack_bits

    acknowledge(network, &channel.seq_send, packet_ack)
    if paws_greater_than(packet_ack, packet_ack_processed){
        for n in 1..=u16(min(32, packet_ack - packet_ack_processed)) {
            ack_minus_n := packet_ack - n
            if int(n) in packet_ack_bits {
                acknowledge(network, &channel.seq_send, ack_minus_n)
            } else {
                message, color := get_data(network, &channel.seq_send, ack_minus_n)
                if message != nil {
                    resend_data_to_channel(network, channel, message^, ack_minus_n, color)
                }
            }
        }
    }
}