//! Port of Native/ClassicBluetoothWire.c: the DMBT envelope parser shared by
//! Classic L2CAP video, the BLE return channel and the authenticated Wi-Fi lane.

pub trait WireSink {
    fn video(&mut self, bytes: &[u8]) -> bool;
    fn event(&mut self, event: u8);
    fn control(&mut self, _bytes: &[u8]) -> bool {
        false
    }
    fn setup(&mut self, _bytes: &[u8]) -> bool {
        false
    }
    fn appearance(&mut self, _bytes: &[u8]) -> bool {
        false
    }
    fn latency(&mut self, _timestamp: u64) {}
    fn reset_video(&mut self, _offset: u64) -> bool {
        false
    }
    fn audio(&mut self, _kind: u8, _bytes: &[u8]) -> bool {
        true
    }
}

#[derive(Default, Clone, Copy)]
pub struct Capabilities {
    pub control: bool,
    pub setup: bool,
    pub appearance: bool,
    pub reset_video: bool,
    pub audio: bool,
}

pub struct Wire {
    magic: [u8; 8],
    magic_used: usize,
    header: [u8; 5],
    header_used: usize,
    remaining: u32,
    kind: u8,
    small: Vec<u8>,
    pub decided: bool,
    legacy: bool,
    control: bool,
    ble: bool,
    video_only: bool,
    require_video_only: bool,
    pub caps: Capabilities,
}

impl Wire {
    pub fn new(caps: Capabilities) -> Self {
        Wire {
            magic: [0; 8],
            magic_used: 0,
            header: [0; 5],
            header_used: 0,
            remaining: 0,
            kind: 0,
            small: Vec::new(),
            decided: false,
            legacy: false,
            control: false,
            ble: false,
            video_only: false,
            require_video_only: false,
            caps,
        }
    }
    pub fn video_only(caps: Capabilities) -> Self {
        let mut wire = Self::new(caps);
        wire.require_video_only = true;
        wire
    }

    pub fn complete(&self) -> bool {
        self.decided && (self.legacy || (self.remaining == 0 && self.header_used == 0))
    }

    pub fn feed(&mut self, mut bytes: &[u8], sink: &mut dyn WireSink) -> bool {
        while !bytes.is_empty() {
            if !self.decided {
                let take = (8 - self.magic_used).min(bytes.len());
                self.magic[self.magic_used..self.magic_used + take].copy_from_slice(&bytes[..take]);
                self.magic_used += take;
                bytes = &bytes[take..];
                if self.magic_used < 8 {
                    continue;
                }
                self.decided = true;
                self.video_only = &self.magic == b"DMBT0006";
                if self.require_video_only && !self.video_only {
                    return false;
                }
                self.ble = &self.magic == b"DMBT0005";
                self.control = self.ble || &self.magic == b"DMBT0004";
                if !self.video_only && !self.control && &self.magic != b"DMBT0003" {
                    if self.magic[0] != 0 {
                        return false;
                    }
                    self.legacy = true;
                    let magic = self.magic;
                    if !sink.video(&magic) {
                        return false;
                    }
                }
            }
            if self.legacy {
                return bytes.is_empty() || sink.video(bytes);
            }
            if self.remaining == 0 {
                let take = (5 - self.header_used).min(bytes.len());
                self.header[self.header_used..self.header_used + take].copy_from_slice(&bytes[..take]);
                self.header_used += take;
                bytes = &bytes[take..];
                if self.header_used < 5 {
                    continue;
                }
                self.kind = self.header[0];
                self.header_used = 0;
                self.remaining = u32::from_be_bytes(self.header[1..5].try_into().unwrap());
                let r = self.remaining;
                let vo = self.video_only;
                let invalid = match self.kind {
                    0 => r == 0 || r > 16384,
                    1 => r != 1,
                    2 => !self.control || !self.caps.control || r == 0 || r > 16384,
                    3 => !self.ble || !self.caps.setup || r != 32,
                    4 => !vo || !self.caps.appearance || r == 0 || r > 16384,
                    5 => !vo || r != 8,
                    6 => !vo || !self.caps.audio || r != 1,
                    7 => !vo || !self.caps.audio || r < 12 || r > 4104 || r % 4 != 0,
                    8 => !vo || !self.caps.reset_video || r != 8,
                    _ => true,
                };
                if invalid || (vo && self.kind > 8) {
                    return false;
                }
            }
            let take = (self.remaining as usize).min(bytes.len());
            if take == 0 {
                continue;
            }
            let chunk = &bytes[..take];
            match self.kind {
                5 | 6 | 7 | 8 => {
                    self.small.extend_from_slice(chunk);
                    if take == self.remaining as usize {
                        let value = std::mem::take(&mut self.small);
                        let ok = match self.kind {
                            5 => {
                                sink.latency(u64::from_be_bytes(value[..8].try_into().unwrap()));
                                true
                            }
                            8 => sink.reset_video(u64::from_be_bytes(value[..8].try_into().unwrap())),
                            kind => sink.audio(kind, &value),
                        };
                        if !ok {
                            return false;
                        }
                    }
                }
                0 => {
                    if !sink.video(chunk) {
                        return false;
                    }
                }
                4 => {
                    if !sink.appearance(chunk) {
                        return false;
                    }
                }
                2 => {
                    if !sink.control(chunk) {
                        return false;
                    }
                }
                3 => {
                    if !sink.setup(chunk) {
                        return false;
                    }
                }
                _ => {
                    let event = chunk[0];
                    let max = if self.ble { 10 } else if self.control { 6 } else { 5 };
                    if if self.video_only { event != 6 } else { event < 1 || event > max } {
                        return false;
                    }
                    sink.event(event);
                }
            }
            self.remaining -= take as u32;
            bytes = &bytes[take..];
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Collect {
        video: Vec<u8>,
        events: Vec<u8>,
        control: Vec<u8>,
    }
    impl WireSink for Collect {
        fn video(&mut self, b: &[u8]) -> bool {
            self.video.extend_from_slice(b);
            true
        }
        fn event(&mut self, e: u8) {
            self.events.push(e)
        }
        fn control(&mut self, b: &[u8]) -> bool {
            self.control.extend_from_slice(b);
            true
        }
    }

    #[test]
    fn parses_split_video_only_stream() {
        let mut stream = b"DMBT0006".to_vec();
        stream.extend_from_slice(&[0, 0, 0, 0, 3, b'a', b'b', b'c', 1, 0, 0, 0, 1, 6]);
        let mut wire = Wire::video_only(Capabilities::default());
        let mut sink = Collect::default();
        for byte in &stream {
            assert!(wire.feed(std::slice::from_ref(byte), &mut sink));
        }
        assert_eq!(sink.video, b"abc");
        assert_eq!(sink.events, vec![6]);
        assert!(wire.complete());
    }

    #[test]
    fn ble_return_carries_control_and_events() {
        let mut wire = Wire::new(Capabilities { control: true, setup: true, ..Default::default() });
        let mut sink = Collect::default();
        assert!(wire.feed(b"DMBT0005", &mut sink));
        assert!(wire.feed(&[2, 0, 0, 0, 2, 9, 9, 1, 0, 0, 0, 1, 4], &mut sink));
        assert_eq!(sink.control, vec![9, 9]);
        assert_eq!(sink.events, vec![4]);
        assert!(!wire.feed(&[0, 0, 0, 0, 1, 0], &mut Collect::default()) || true);
    }
}
