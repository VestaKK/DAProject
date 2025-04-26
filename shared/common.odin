package shared

import "core:net"

MAX_PLAYER_COUNT :: 3

Packet_Type :: enum u8 {
    Create_Lobby,
    Get_Lobby,
    Join_Lobby,
    Leave_Lobby,
    Start_Game,
}

Lobby_Public :: struct {
    lobby_id: i64,
    player_count: i64,
    lobby_name: string,
    host_name: string,
}

Private_Profile :: struct {
    endpoint: net.Endpoint,
    assigned_id: i64,
    name: string,
}

Create_Lobby_Packet :: struct {
    lobby_id: i64,
    lobby_name: string,
    host_name: string,
}

Join_Lobby_Packet :: struct {
    lobby_id: i64,
    join_name: string,
}

Start_Lobby_Packet :: struct {
    lobby_id: i64,
    assigned_id: i64,
}

Leave_Lobby_Packet :: struct {
    lobby_id: i64,
    assigned_id: i64,
}

Packet :: union {
    Create_Lobby_Packet,
    Join_Lobby_Packet,
    Leave_Lobby_Packet,
    Start_Lobby_Packet,
}

Create_Response :: struct {
    assigned_id: i64,
}

Join_Lobby_Response :: struct {
    lobby_name: string,
    assigned_id: i64,
}

Leave_Lobby_Response :: struct {}

Start_Lobby_Response :: struct {
    players: [MAX_PLAYER_COUNT]Private_Profile,
    count: i64,
}

Error :: string
Response :: union {
    Error,
    Create_Response,
    Join_Lobby_Response,
    Leave_Lobby_Response,
    Start_Lobby_Response,
}

