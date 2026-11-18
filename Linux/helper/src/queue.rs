//! Port of Native/BleInputQueue.m: assembles scrcpy control messages into
//! BLE records, coalesces pointer motion and wheel deltas under backpressure,
//! rewrites timestamped touches onto the phone clock, and interleaves video
//! acknowledgements and Bluetooth-video recovery requests at record boundaries.

use std::collections::VecDeque;

fn read32(p: &[u8]) -> u32 {
    u32::from_be_bytes(p[..4].try_into().unwrap())
}
fn read16(p: &[u8]) -> u16 {
    u16::from_be_bytes(p[..2].try_into().unwrap())
}

/// Lengths match the bundled scrcpy 5 control serializer. `Some(0)` means
/// "need more bytes"; `None` is an unknown message type.
fn control_size(p: &[u8]) -> Option<usize> {
    let n = p.len();
    if n == 0 {
        return Some(0);
    }
    Some(match p[0] {
        0 => 14,
        1 | 22 => {
            if n < 5 {
                0
            } else {
                5 + read32(&p[1..]) as usize
            }
        }
        2 => 32,
        23 => 40,
        26 => 6,
        3 | 24 => 21,
        4 | 8 | 10 | 18 => 2,
        25 | 5 | 6 | 7 | 11 | 15 | 17 | 19 | 20 => 1,
        9 => {
            if n < 14 {
                0
            } else {
                14 + read32(&p[10..]) as usize
            }
        }
        12 => {
            if n < 8 {
                0
            } else {
                let descriptor = 8 + p[7] as usize;
                if n < descriptor + 2 { 0 } else { descriptor + 2 + read16(&p[descriptor..]) as usize }
            }
        }
        13 => {
            if n < 5 {
                0
            } else {
                5 + read16(&p[3..]) as usize
            }
        }
        14 => 3,
        16 => {
            if n < 2 {
                0
            } else {
                2 + p[1] as usize
            }
        }
        21 => 5,
        _ => return None,
    })
}

fn same_pointer_move(previous: &[u8], next: &[u8]) -> bool {
    if previous.len() != next.len() || (previous.len() != 37 && previous.len() != 45) {
        return false;
    }
    let a = &previous[5..];
    let b = &next[5..];
    (a[0] == 2 || a[0] == 23)
        && a[0] == b[0]
        && (a[1] == 2 || a[1] == 7)
        && a[1] == b[1]
        && a[2..10] == b[2..10]
        && a[18..32] == b[18..32]
}

struct Record {
    bytes: Vec<u8>,
    motion: bool,
    wheel: bool,
    bucket: u64,
}

pub struct InputQueue {
    records: VecDeque<Record>,
    input: Vec<u8>,
    active: Option<Vec<u8>>,
    offset: usize,
    pending_bytes: usize,
    remaining_control: usize,
    ack_pending: bool,
    fallback: Option<Vec<u8>>,
    latest_ack: u64,
    last_motion: f64,
    last_motion_bucket: u64,
    last_motion_bytes: Vec<u8>,
    clock_ready: bool,
    phone_clock_offset: i64,
    latest_motion_only: bool,
}

impl InputQueue {
    pub fn new() -> Self {
        InputQueue {
            records: VecDeque::new(),
            input: Vec::new(),
            active: None,
            offset: 0,
            pending_bytes: 0,
            remaining_control: 0,
            ack_pending: false,
            fallback: None,
            latest_ack: 0,
            last_motion: -1.0,
            last_motion_bucket: 0,
            last_motion_bytes: Vec::new(),
            clock_ready: false,
            phone_clock_offset: 0,
            latest_motion_only: false,
        }
    }
    /// Source time base: CLOCK_MONOTONIC, matching the clock synchronized
    /// against the phone and the timestamps in scrcpy's timestamped touches.
    fn clock(&self) -> f64 {
        monotonic_secs()
    }
    pub fn pending_bytes(&self) -> usize {
        self.pending_bytes + self.input.len()
    }
    pub fn has_work(&self) -> bool {
        self.pending_bytes > 0 || self.ack_pending || self.fallback.is_some()
    }
    pub fn motion_delay(&self) -> f64 {
        if self.active.is_some() || self.ack_pending || self.fallback.is_some() || self.last_motion < 0.0 {
            return 0.0;
        }
        let Some(first) = self.records.front() else { return 0.0 };
        if !first.motion || self.records.len() > 1 || first.bucket != self.last_motion_bucket {
            return 0.0;
        }
        if !same_pointer_move(&self.last_motion_bytes, &first.bytes) {
            return 0.0;
        }
        (self.last_motion + 1.0 / 60.0 - self.clock()).max(0.0)
    }

    pub fn append_records(&mut self, bytes: &[u8]) -> bool {
        if bytes.is_empty() || self.pending_bytes() >= 128 * 1024 || bytes.len() > 128 * 1024 - self.pending_bytes() {
            return false;
        }
        let mut input = self.input.clone();
        let mut offset = 0;
        while offset < bytes.len() {
            if bytes.len() - offset < 5 || bytes[offset] != 0 {
                return false;
            }
            let length = read32(&bytes[offset + 1..]) as usize;
            if length == 0 || length > 4096 || length > bytes.len() - offset - 5 {
                return false;
            }
            input.extend_from_slice(&bytes[offset + 5..offset + 5 + length]);
            offset += length + 5;
        }
        let mut records = Vec::new();
        let mut consumed = 0;
        let mut remaining = self.remaining_control;
        while consumed < input.len() {
            let raw = &input[consumed..];
            let available = raw.len();
            let message_start = remaining == 0;
            let length;
            if remaining > 0 {
                length = remaining.min(available);
                remaining -= length;
            } else {
                let Some(size) = control_size(raw) else { return false };
                if size > 256 * 1024 {
                    return false;
                }
                if size == 0 {
                    break;
                }
                if size > available {
                    if size <= 4096 {
                        break;
                    }
                    remaining = size - available;
                    length = available;
                } else {
                    length = size;
                }
            }
            let mut chunk_offset = 0;
            while chunk_offset < length {
                let count = 4096.min(length - chunk_offset);
                let mut record = Vec::with_capacity(count + 5);
                record.push(0);
                record.extend_from_slice(&(count as u32).to_be_bytes());
                record.extend_from_slice(&raw[chunk_offset..chunk_offset + count]);
                let wheel = message_start && length == 21 && raw[0] == 24 && (read32(&raw[13..]) != 0 || read32(&raw[17..]) != 0);
                let motion = message_start
                    && ((length == 32 && raw[0] == 2) || (length == 40 && raw[0] == 23))
                    && (raw[1] == 2 || raw[1] == 7);
                let mut source_time = (self.clock() * 1000.0) as u64;
                if message_start && length == 40 && raw[0] == 23 {
                    if !self.clock_ready {
                        return false;
                    }
                    let timestamp = u64::from_be_bytes(raw[32..40].try_into().unwrap());
                    source_time = timestamp;
                    if timestamp > i64::MAX as u64 || (timestamp as i64) + self.phone_clock_offset < 0 {
                        return false;
                    }
                    let phone = ((timestamp as i64) + self.phone_clock_offset) as u64;
                    record[37..45].copy_from_slice(&phone.to_be_bytes());
                }
                let bucket = (source_time / 1000) * 60 + (source_time % 1000) * 60 / 1000;
                records.push(Record { bytes: record, motion, wheel, bucket });
                chunk_offset += 4096;
            }
            consumed += length;
        }
        input.drain(..consumed);
        self.input = input;
        self.remaining_control = remaining;
        for record in records {
            self.enqueue(record);
        }
        true
    }

    pub fn set_latest_motion_only(&mut self, value: bool) {
        if self.latest_motion_only == value {
            return;
        }
        self.latest_motion_only = value;
        if !value {
            return;
        }
        let queued: Vec<Record> = self.records.drain(..).collect();
        for record in queued {
            self.pending_bytes -= record.bytes.len();
            self.enqueue(record);
        }
    }
    pub fn latest_motion_only(&self) -> bool {
        self.latest_motion_only
    }

    fn enqueue(&mut self, mut record: Record) {
        let payload = &record.bytes[5..];
        if record.bytes.len() == 26 && payload[0] == 24 && read32(&payload[13..]) == 0 && read32(&payload[17..]) == 0 {
            // A fresh trackpad gesture cancels unsent momentum.
            while self.records.back().is_some_and(|r| r.wheel) {
                let last = self.records.pop_back().unwrap();
                self.pending_bytes -= last.bytes.len();
            }
        }
        if record.motion {
            let mut i = self.records.len();
            while i > 0 {
                let previous = &self.records[i - 1];
                if !previous.motion || (!self.latest_motion_only && previous.bucket != record.bucket) {
                    break;
                }
                if same_pointer_move(&previous.bytes, &record.bytes) {
                    if self.latest_motion_only && previous.bucket < record.bucket && record.bucket - previous.bucket < 6 {
                        i -= 1;
                        continue;
                    }
                    let removed = self.records.remove(i - 1).unwrap();
                    self.pending_bytes -= removed.bytes.len();
                    if !self.latest_motion_only {
                        break;
                    }
                    i -= 1;
                    continue;
                }
                let a = &previous.bytes[5..];
                let b = &record.bytes[5..];
                if previous.bytes.len() != record.bytes.len() || a[0] != b[0] || a[1] != b[1] || a[18..32] != b[18..32] {
                    break;
                }
                i -= 1;
            }
        }
        if record.wheel {
            if let Some(last) = self.records.back_mut() {
                if last.wheel && last.bytes[6..18] == record.bytes[6..18] {
                    let a = &last.bytes[5..];
                    let b = &record.bytes[5..];
                    let dx = read32(&a[13..]) as i32 as i64 + read32(&b[13..]) as i32 as i64;
                    let dy = read32(&a[17..]) as i32 as i64 + read32(&b[17..]) as i32 as i64;
                    if (i32::MIN as i64..=i32::MAX as i64).contains(&dx) && (i32::MIN as i64..=i32::MAX as i64).contains(&dy) {
                        last.bytes[18..22].copy_from_slice(&(dx as i32 as u32).to_be_bytes());
                        last.bytes[22..26].copy_from_slice(&(dy as i32 as u32).to_be_bytes());
                        return;
                    }
                }
            }
        }
        self.pending_bytes += record.bytes.len();
        record.bytes.shrink_to_fit();
        self.records.push_back(record);
    }

    pub fn synchronize_phone_clock(&mut self, phone: u64, local: u64) {
        self.phone_clock_offset = phone as i64 - local as i64;
        self.clock_ready = true;
    }
    pub fn acknowledge_video(&mut self, count: u64) {
        self.latest_ack = count;
        self.ack_pending = true;
    }
    pub fn request_bluetooth_video(&mut self, count: u64, nonce: &[u8; 32]) {
        let mut record = vec![2, 0, 0, 0, 40];
        record.extend_from_slice(nonce);
        record.extend_from_slice(&count.to_be_bytes());
        self.fallback = Some(record);
    }

    pub fn take_packet(&mut self, maximum: usize) -> Option<Vec<u8>> {
        if maximum == 0 {
            return None;
        }
        let mut packet = Vec::new();
        while packet.len() < maximum {
            if self.active.is_none() {
                if let Some(fallback) = self.fallback.take() {
                    self.pending_bytes += fallback.len();
                    self.active = Some(fallback);
                } else if self.ack_pending {
                    let mut ack = vec![1, 0, 0, 0, 8];
                    ack.extend_from_slice(&self.latest_ack.to_be_bytes());
                    self.pending_bytes += ack.len();
                    self.active = Some(ack);
                    self.ack_pending = false;
                } else if !self.records.is_empty() {
                    if self.motion_delay() > 0.0 {
                        break;
                    }
                    let record = self.records.pop_front().unwrap();
                    if record.motion {
                        self.last_motion = self.clock();
                        self.last_motion_bucket = record.bucket;
                        self.last_motion_bytes = record.bytes.clone();
                    }
                    self.active = Some(record.bytes);
                } else {
                    break;
                }
                self.offset = 0;
            }
            let active = self.active.as_ref().unwrap();
            let length = (maximum - packet.len()).min(active.len() - self.offset);
            packet.extend_from_slice(&active[self.offset..self.offset + length]);
            self.offset += length;
            self.pending_bytes -= length;
            if self.offset == active.len() {
                self.active = None;
                self.offset = 0;
            }
        }
        if packet.is_empty() { None } else { Some(packet) }
    }

    pub fn clear(&mut self) {
        self.records.clear();
        self.input.clear();
        self.active = None;
        self.offset = 0;
        self.pending_bytes = 0;
        self.remaining_control = 0;
        self.ack_pending = false;
        self.fallback = None;
        self.last_motion = -1.0;
    }
}

pub fn monotonic_ms() -> u64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    now.tv_sec as u64 * 1000 + now.tv_nsec as u64 / 1_000_000
}

pub fn monotonic_secs() -> f64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    now.tv_sec as f64 + now.tv_nsec as f64 / 1e9
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wrap(message: &[u8]) -> Vec<u8> {
        let mut out = vec![0];
        out.extend_from_slice(&(message.len() as u32).to_be_bytes());
        out.extend_from_slice(message);
        out
    }

    #[test]
    fn splits_and_reassembles_key_events() {
        let mut queue = InputQueue::new();
        let key = [0u8; 14];
        assert!(queue.append_records(&wrap(&key[..6])));
        assert!(!queue.has_work());
        assert!(queue.append_records(&wrap(&key[6..])));
        let packet = queue.take_packet(488).unwrap();
        assert_eq!(packet.len(), 19);
        assert_eq!(&packet[..5], &[0, 0, 0, 0, 14]);
    }

    #[test]
    fn coalesces_same_bucket_moves() {
        let mut queue = InputQueue::new();
        let mut moving = [0u8; 32];
        moving[0] = 2;
        moving[1] = 2;
        assert!(queue.append_records(&wrap(&moving)));
        moving[11] = 9; // position changes
        assert!(queue.append_records(&wrap(&moving)));
        let packet = queue.take_packet(488).unwrap();
        assert_eq!(packet.len(), 37);
        assert_eq!(packet[5 + 11], 9);
    }

    #[test]
    fn ack_preempts_records_at_boundary() {
        let mut queue = InputQueue::new();
        queue.acknowledge_video(42);
        let packet = queue.take_packet(13).unwrap();
        assert_eq!(packet[0], 1);
        assert_eq!(u64::from_be_bytes(packet[5..13].try_into().unwrap()), 42);
    }
}
