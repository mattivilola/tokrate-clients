//! A minimal, read-only decoder for the protobuf wire format.
//!
//! Antigravity stores protobuf messages without a published schema, so Tokrate reads the wire
//! format directly and looks up only the field numbers it needs. Anything that is not a valid
//! message (an unknown wire type, a group, a truncated value, field number 0) makes the whole
//! blob unreadable rather than partially trusted.

/// One decoded field value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WireValue<'a> {
    Varint(u64),
    Fixed64(u64),
    Bytes(&'a [u8]),
    Fixed32(u32),
}

/// A present field has another wire type than the reader asked for, or a nested message or
/// string value is unreadable. Absent fields are not an error: proto3 omits default values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Malformed;

const MAX_FIELD_NUMBER: u64 = (1 << 29) - 1;

/// The top-level fields of one message, in wire order.
#[derive(Clone, Debug)]
pub(crate) struct Message<'a> {
    fields: Vec<(u32, WireValue<'a>)>,
}

impl<'a> Message<'a> {
    /// Decodes a whole message; `None` when any part of it is not valid wire format. Nested
    /// messages stay raw bytes until [`Message::message`] asks for one.
    pub fn parse(bytes: &'a [u8]) -> Option<Self> {
        let mut fields = Vec::new();
        let mut rest = bytes;
        while !rest.is_empty() {
            let (tag, after_tag) = read_varint(rest)?;
            let number = tag >> 3;
            if number == 0 || number > MAX_FIELD_NUMBER {
                return None;
            }
            let (value, after_value) = match tag & 7 {
                0 => {
                    let (value, after) = read_varint(after_tag)?;
                    (WireValue::Varint(value), after)
                }
                1 => {
                    let (raw, after) = take(after_tag, 8)?;
                    let value = u64::from_le_bytes(raw.try_into().ok()?);
                    (WireValue::Fixed64(value), after)
                }
                2 => {
                    let (length, after) = read_varint(after_tag)?;
                    let (raw, after) = take(after, usize::try_from(length).ok()?)?;
                    (WireValue::Bytes(raw), after)
                }
                5 => {
                    let (raw, after) = take(after_tag, 4)?;
                    let value = u32::from_le_bytes(raw.try_into().ok()?);
                    (WireValue::Fixed32(value), after)
                }
                // Groups (3, 4) and the reserved types (6, 7) are not valid here.
                _ => return None,
            };
            fields.push((number as u32, value));
            rest = after_value;
        }
        Some(Self { fields })
    }

    /// The last occurrence of a singular field, as proto3 parsers resolve repeats.
    fn last(&self, number: u32) -> Option<WireValue<'a>> {
        self.fields
            .iter()
            .rev()
            .find(|(field, _)| *field == number)
            .map(|(_, value)| *value)
    }

    /// A varint field; `Ok(None)` when absent (the caller applies the proto3 default).
    pub fn varint(&self, number: u32) -> Result<Option<u64>, Malformed> {
        match self.last(number) {
            None => Ok(None),
            Some(WireValue::Varint(value)) => Ok(Some(value)),
            Some(_) => Err(Malformed),
        }
    }

    /// A nested message field; `Ok(None)` when absent.
    pub fn message(&self, number: u32) -> Result<Option<Message<'a>>, Malformed> {
        match self.last(number) {
            None => Ok(None),
            Some(WireValue::Bytes(raw)) => Message::parse(raw).map(Some).ok_or(Malformed),
            Some(_) => Err(Malformed),
        }
    }

    /// A UTF-8 string field; `Ok(None)` when absent.
    pub fn string(&self, number: u32) -> Result<Option<&'a str>, Malformed> {
        match self.last(number) {
            None => Ok(None),
            Some(WireValue::Bytes(raw)) => {
                std::str::from_utf8(raw).map(Some).map_err(|_| Malformed)
            }
            Some(_) => Err(Malformed),
        }
    }

    /// Every occurrence of a repeated message field, in wire order.
    pub fn messages(&self, number: u32) -> Result<Vec<Message<'a>>, Malformed> {
        self.fields
            .iter()
            .filter(|(field, _)| *field == number)
            .map(|(_, value)| match value {
                WireValue::Bytes(raw) => Message::parse(raw).ok_or(Malformed),
                _ => Err(Malformed),
            })
            .collect()
    }
}

fn take(bytes: &[u8], count: usize) -> Option<(&[u8], &[u8])> {
    (bytes.len() >= count).then(|| bytes.split_at(count))
}

/// A little-endian base-128 varint of at most ten bytes that fits 64 bits.
fn read_varint(bytes: &[u8]) -> Option<(u64, &[u8])> {
    let mut value = 0u64;
    for (index, byte) in bytes.iter().take(10).enumerate() {
        let bits = u64::from(byte & 0x7f);
        if index == 9 && bits > 1 {
            return None;
        }
        value |= bits << (7 * index);
        if byte & 0x80 == 0 {
            return Some((value, &bytes[index + 1..]));
        }
    }
    None
}
