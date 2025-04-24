package shared

Packet_Type :: enum u8 {
    Create_Lobby,
    Get_Lobby,
    Join_Lobby,
    Start_Game,
}

Create_Lobby_Packet :: struct {
    name: string,
    size: int,
}

Join_Lobby_Packet :: struct {
    id: i64,
}

Start_Game_Packet :: struct {
    id: i64,
}

Get_Lobby_Packet :: struct {
    num: i64,
}

Packet :: union {
    Create_Lobby_Packet,
    Join_Lobby_Packet,
    Start_Game_Packet,
    Get_Lobby_Packet,
}