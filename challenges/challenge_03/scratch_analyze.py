def main():
    # Simulate FPGA LFSR and serialization
    lfsr = 0xACE1
    
    def lfsr_feedback(val):
        bit15 = (val >> 15) & 1
        bit14 = (val >> 14) & 1
        bit12 = (val >> 12) & 1
        bit3  = (val >> 3) & 1
        return bit15 ^ bit14 ^ bit12 ^ bit3

    # The FPGA sends 10,000 data bytes.
    # b[0] is the initial lfsr[7:0]
    # Then lfsr shifts, and we send the next lfsr[7:0]
    data_bytes = []
    curr_lfsr = lfsr
    for i in range(10000):
        data_bytes.append(curr_lfsr & 0xFF)
        feedback = lfsr_feedback(curr_lfsr)
        curr_lfsr = ((curr_lfsr << 1) | feedback) & 0xFFFF

    print(f"First 10 FPGA data bytes (b_0..b_9): {[hex(x) for x in data_bytes[:10]]}")
    
    # Pack them as the FPGA does:
    # 4 header bytes: 10000 in little endian
    bytes_sent = [0x10, 0x27, 0x00, 0x00]
    
    # 5th byte is b_0 in full
    bytes_sent.append(data_bytes[0])
    
    # Subsequent bytes are packed LSBs
    pack_buf = 0
    pack_len = 0
    for k in range(1, 10000):
        lsb = data_bytes[k] & 1
        pack_buf |= (lsb << pack_len)
        if pack_len == 7:
            bytes_sent.append(pack_buf)
            pack_buf = 0
            pack_len = 0
        else:
            pack_len += 1
            
    # Last byte padding (simulating the FPGA bug/correct way)
    if pack_len > 0:
        # Currently the FPGA does: serialize_data <= {tx_data[0], pack_buf[6:0]}
        # Since pack_len is 6 at the end (for 9999 bits):
        # pack_buf has bits 0..5 filled.
        # tx_data[0] is data_bytes[9999] & 1.
        # The FPGA sends {tx_data[0], pack_buf[6:0]} where pack_buf[6] is some old value (0)
        last_byte = ((data_bytes[9999] & 1) << 7) | (pack_buf & 0x7F)
        bytes_sent.append(last_byte)

    print(f"Expected sent bytes 0..10: {[hex(x) for x in bytes_sent[:15]]}")

    # The user says ESP32 received:
    # rx_buffer[0] = 0xE0 (or 0xE1)
    # rx_buffer[1] = 0xAC
    # rx_buffer[2] = 0xE1
    # rx_buffer[3] = 0x86
    # In little endian, this is 0x86E1ACE0 or 0x86E1ACE1
    
    target_bytes_1 = [0xE0, 0xAC, 0xE1, 0x86]
    target_bytes_2 = [0xE1, 0xAC, 0xE1, 0x86]
    
    # Let's search if these 4-byte sequences exist anywhere in bytes_sent
    for target in [target_bytes_1, target_bytes_2]:
        found = False
        for idx in range(len(bytes_sent) - 4):
            if bytes_sent[idx:idx+4] == target:
                print(f"Found match for {target} at byte index {idx}!")
                found = True
        if not found:
            print(f"No match for {target} in the byte stream.")

if __name__ == "__main__":
    main()
