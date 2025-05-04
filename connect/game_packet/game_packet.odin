package game_package

import "core:encoding/cbor"
import "core:net"
import sa "core:container/small_array"
import "base:runtime"

SEQUENCE_BUFFER_SIZE :: 1024
MAX_CONNECTIONS :: 4

buf: [1024]byte

Network :: struct {
    host_id: int,
    socket: net.UDP_Socket,
    channels: sa.Small_Array(MAX_CONNECTIONS, Channel),
    net_allocator: runtime.Allocator,
    net_temp: runtime.Allocator,
    msg_allocator: runtime.Allocator,
    msg_temp: runtime.Allocator,
    msg_delete_proc: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator),
    message_queue: [dynamic]Message,
}

@private
_delete_message :: proc(network: ^Network, message: Message) {
    network.msg_delete_proc(message, network.msg_allocator, network.msg_temp)
}

Channel :: struct {
    id: i8,
    color: Color,
    seq: u16,
    ack: u16,
    ack_processed: u16,
    endpoint: net.Endpoint,
    seq_send: Sequence_Buffer,
    buf_recv: [SEQUENCE_BUFFER_SIZE]u32,
    unprocessed: [dynamic]Message,
}

Sequence_Buffer :: struct {
    buf_seq: [SEQUENCE_BUFFER_SIZE]u32,
    buf_col: [SEQUENCE_BUFFER_SIZE]Color,
    buf_msg: []Message,
}

init_sequence_buffer :: proc(network: ^Network, sbuffer: ^Sequence_Buffer)  {
    for &sequence in sbuffer.buf_seq{
        sequence = max(u32)
    }
    sbuffer.buf_msg = make([]Message, SEQUENCE_BUFFER_SIZE, network.net_allocator)
}

delete_sequence_buffer :: proc(network: ^Network, sbuffer: ^Sequence_Buffer) {
    for &sequence, i in sbuffer.buf_seq{
        if sequence != max(u32) {
            _delete_message(network, sbuffer.buf_msg[i])
        }
    }
}

get_ack_bits :: proc(buf_recv: [SEQUENCE_BUFFER_SIZE]u32, ack: u16) -> bit_set[1..=32; u32] {
    out: bit_set[1..=32; u32]
    for n in 1..=u16(32) {
        // ack = 0, prev_sequence = 65,535
        ack_minus_n := ack - n

        // prev_seq = 65,535, index = 1023
        index := ack_minus_n % SEQUENCE_BUFFER_SIZE

        // if sbuffer[1023] == 65,535 -> this has been seen before
        if buf_recv[index] == u32(ack_minus_n) { 

            // I now know that sequence u16(0 - 1) was recieved by this client (seq - n)
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

put_message:: proc(network: ^Network, sbuffer: ^Sequence_Buffer, message: Message, sequence: u16, color: Color) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    old_data: Data 
    if sbuffer.buf_seq[index] != max(u32) {

        // get the old data
        old_data = sbuffer.buf_msg[index]

        // since its getting replaced we can delete it
        _delete_message(network, sbuffer.buf_msg[index])
    }

    // set new sequence number
    sbuffer.buf_seq[index] = u32(sequence)

    // set color of message
    sbuffer.buf_col[index] = color

    // set new data
    sbuffer.buf_msg[index] = message
}

put_buf_recv :: proc(buf_recv: ^[SEQUENCE_BUFFER_SIZE]u32, sequence: u16) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    buf_recv[index] = u32(sequence)
}

acknowledge :: proc(network: ^Network, sbuffer: ^Sequence_Buffer, sequence: u16) {
    index := sequence % SEQUENCE_BUFFER_SIZE
    if sbuffer.buf_seq[index] != max(u32) {
        acked_data := sbuffer.buf_msg[index]
        _delete_message(network, acked_data)
        sbuffer.buf_seq[index] = max(u32)
    }
}

Color :: enum u8 {
    None,
    Red,
    White,
    Blue,
}

@(private)
Header :: struct #packed {
    color: Color,
    from: i8,
    seq: u16,
    ack: u16,
    ack_processed: u16,
    ack_bits: bit_set[1..=32; u32],
}

Keep_Alive :: struct {}
Marker :: struct {}
Internal :: union {
    Keep_Alive,
    Marker,
}

Message :: union {
    struct{}
}

Data :: union #shared_nil {
    Internal,
    Message,
}

Packet :: struct {
    header: Header,
    data: Data,
}

init_network :: proc(
    network: ^Network,
    socket: net.UDP_Socket,
    host_endpoint: net.Endpoint,
    msg_allocator: runtime.Allocator,
    msg_temp: runtime.Allocator,
    msg_delete_proc: proc(message: Message, allocator: runtime.Allocator, temp_allocator: runtime.Allocator),
    net_allocator := context.allocator,
    net_temp:= context.temp_allocator,
) -> (host_id: int, ok: bool) { 
    if network.net_allocator != {} {
        return
    }
    host_id = add_connection(network, host_endpoint) or_return
    network.host_id = host_id
    network.socket = socket
    network.msg_allocator = msg_allocator
    network.msg_temp = msg_temp
    network.msg_delete_proc = msg_delete_proc
    network.net_allocator = net_allocator
    network.net_temp = net_temp
    network.message_queue = make([dynamic]Message)
    return
}

close_network :: proc(network: ^Network) {
    for &channel in sa.slice(&network.channels) {
        delete_channel(network, &channel)
    }
    cleanup_messages(network)
    delete(network.message_queue)
}

add_connection :: proc(network: ^Network, endpoint: net.Endpoint) -> (channel_id: int, ok: bool) {
    if network.net_allocator == {} {
        return
    }
    new_id := network.channels.len
    new_channel := Channel{
        id = i8(new_id),
        color = .White,
        endpoint = endpoint,
    }
    new_channel.unprocessed = make([dynamic]Message)
    init_sequence_buffer(network, &new_channel.seq_send) 
    for &sequence in new_channel.buf_recv {
        sequence = max(u32)
    }
    sa.push_back(&network.channels, new_channel) or_return
    return new_id, true
}

@private
delete_channel :: proc(network: ^Network, channel: ^Channel) {
    delete_sequence_buffer(network, &channel.seq_send)
    for message in channel.unprocessed {
        _delete_message(network, message)
    }
    delete(channel.unprocessed)
}

@private
_broadcast_data :: proc(network: ^Network, data: Data, should_ack := false) -> bool {
    for &channel in sa.slice(&network.channels) {
        udp_err := _send_data_to_channel(network, data, &channel)
        if udp_err != nil {
            return false
        }    
    }
    return true
}

@private
_send_data:: proc(network: ^Network, data: Data, net_id: int) -> bool {
    if net_id >= MAX_CONNECTIONS {
        return false
    }
    udp_err := _send_data_to_channel(network, data, sa.get_ptr(&network.channels, net_id))
    if udp_err != nil {
        return false
    }
    return true
}

@private
_send_data_to_channel :: proc(network: ^Network, data: Data, channel: ^Channel, should_ack := false) -> net.UDP_Send_Error { 
    packet: Packet
    packet.header.from = channel.id
    packet.header.color = channel.color
    packet.header.seq = channel.seq
    packet.header.ack = channel.ack
    packet.header.ack_bits = get_ack_bits(channel.buf_recv, channel.ack)
    packet.data = data 

    if message, ok := data.(Message); ok {
        put_message(network, &channel.seq_send, message, channel.seq, channel.color)
        channel.seq += 1
    }

    bytes, marshal_err := cbor.marshal_into_bytes(packet, cbor.ENCODE_SMALL, network.net_allocator, network.net_temp)
    defer delete(bytes)

    net.send_udp(network.socket, bytes, channel.endpoint) or_return
    return nil
}

poll_for_packets :: proc(network: ^Network) {
    for {
        bytes_read, _, recv_err := net.recv_udp(network.socket, buf[:])
        if bytes_read == 0 {
            break
        }
        packet: Packet
        cbor.unmarshal(transmute(string)buf[:bytes_read], &packet, {}, network.msg_allocator, network.msg_temp)
        deal_with_packet(network, packet)
    }
}

get_messages :: proc(network: ^Network) -> []Message {
    for &channel in sa.slice(&network.channels) {
        for message in channel.unprocessed {
            if message != nil {
                append(&network.message_queue, message)
            }
        }
    }
    return nil
}

cleanup_messages :: proc(network: ^Network) {
    for message in network.message_queue {
        _delete_message(network, message)
    }
    clear(&network.message_queue)
}

_resend_data_to_channel :: proc(network: ^Network, channel: ^Channel, data: Data, sequence: u16, color: Color) -> net.UDP_Send_Error {
    packet: Packet
    packet.header.from = channel.id
    packet.header.color = channel.color
    packet.header.seq = sequence
    packet.header.ack = channel.ack
    packet.header.ack_processed = channel.ack_processed
    packet.header.ack_bits = get_ack_bits(channel.buf_recv, channel.ack)
    packet.data = data 

    if message, ok := data.(Message); ok {
        put_message(network, &channel.seq_send, message, channel.seq, color)
        channel.seq += 1
    }

    bytes, marshal_err := cbor.marshal_into_bytes(packet, cbor.ENCODE_SMALL, network.net_allocator, network.net_temp)
    defer delete(bytes)

    net.send_udp(network.socket, bytes, channel.endpoint) or_return
    return nil
}

// PAWS == Protect Against Wrap Around
paws_greater_than :: proc(a, b: u16) -> bool {
    HALF_RANGE :: u16(1 << 15)
    diff := a - b
    return diff > 0 && diff < HALF_RANGE 
}

deal_with_packet :: proc(network: ^Network, packet: Packet) {
    channel := sa.get_ptr(&network.channels, int(packet.header.from))
    packet_seq := packet.header.seq
    packet_ack := packet.header.ack

    // Most recent seq in buffer
    if paws_greater_than(channel.ack, packet_seq) {
        // add to end of unprocessed queue
        if message, ok := packet.data.(Message); ok {
            put_buf_recv(&channel.buf_recv, packet_seq)

            // if channel.ack == 40 and packet.header == 41, then hopefully no nil entries are filled
            for _ in 0..<(channel.ack - packet_seq - 1) {
                append(&channel.unprocessed, nil)
            }
            append(&channel.unprocessed, message)
        }
        channel.ack = packet_seq

    // If we can still reinsert the message
    // packet_seq == 3
    // channel.ack_processed == 0
    // index = 2
    // channel.unprocessed == [1, 2, nil, 4, 5]

    // packet_seq == 65535
    // channel.ack_processed  == 65534
    // index == 0
    // channel.unprocessed == [nil, 0, 1]
    } else if paws_greater_than(channel.ack_processed, packet_seq) {
        if message, ok := packet.data.(Message); ok {
            index := packet_seq - channel.ack_processed - 1
            if channel.unprocessed[index] != nil {
                channel.unprocessed[index] = message
            }
        }

    // Ignore message
    } else {
        if message, ok := packet.data.(Message); ok {
            _delete_message(network, message)
        }
    }

    // Check header for acknowledgements
    acknowledge(network, &channel.seq_send, packet.header.ack)
    for n in 1..=u16(min(32, packet.header.ack - packet.header.ack_processed)) {
        ack_minus_n := channel.ack - n
        if int(n) in packet.header.ack_bits {
            acknowledge(network, &channel.seq_send, ack_minus_n)
        } else {
            message, color := get_data(network, &channel.seq_send, ack_minus_n)
            if message != nil {
                _resend_data_to_channel(network, channel, message^, ack_minus_n, color)
            }
        }
    }
}