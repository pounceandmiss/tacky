-- XEP-0421 occupant-ids a room vouched for, and the real bare JID the
-- occupant's presence carried. A room's archive names a message's sender by
-- occupant-id alone, so this is what attributes history from someone no
-- longer in the room (OMEMO decrypts it with that JID's session). The first
-- JID seen for an id is kept: XEP-0421 gives each real JID its own id.
CREATE TABLE IF NOT EXISTS muc_occupant(
    room_jid     TEXT NOT NULL,
    occupant_id  TEXT NOT NULL,
    real_jid     TEXT NOT NULL,
    PRIMARY KEY(room_jid, occupant_id)
);
