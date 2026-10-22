-- Our sends still waiting for the server: the pending-send retry, the SM
-- ack and the OMEMO session-ready paths read just these rows, which
-- otherwise meant every row of the account. A query takes it only when it
-- spells server_status='pending' literally.
CREATE INDEX IF NOT EXISTS idx_chat_message_pending
    ON chat_message(timestamp) WHERE server_status='pending';
