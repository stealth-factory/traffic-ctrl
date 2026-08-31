use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub fn is_public_address(value: &str) -> bool {
    value.parse::<IpAddr>().is_ok_and(|address| match address {
        IpAddr::V4(address) => is_public_ipv4(address),
        IpAddr::V6(address) => is_public_ipv6(address),
    })
}

fn is_public_ipv4(address: Ipv4Addr) -> bool {
    let value = u32::from(address);
    let matches = |network: u32, mask: u32| value & mask == network;
    !matches(0x0000_0000, 0xFF00_0000)
        && !matches(0x0A00_0000, 0xFF00_0000)
        && !matches(0x6440_0000, 0xFFC0_0000)
        && !matches(0x7F00_0000, 0xFF00_0000)
        && !matches(0xA9FE_0000, 0xFFFF_0000)
        && !matches(0xAC10_0000, 0xFFF0_0000)
        && !matches(0xC000_0000, 0xFFFF_FF00)
        && !matches(0xC000_0200, 0xFFFF_FF00)
        && !matches(0xC0A8_0000, 0xFFFF_0000)
        && !matches(0xC612_0000, 0xFFFE_0000)
        && !matches(0xC633_6400, 0xFFFF_FF00)
        && !matches(0xCB00_7100, 0xFFFF_FF00)
        && !matches(0xE000_0000, 0xF000_0000)
        && !matches(0xF000_0000, 0xF000_0000)
}

fn is_public_ipv6(address: Ipv6Addr) -> bool {
    let bytes = address.octets();
    let globally_routed_unicast = bytes[0] & 0xE0 == 0x20;
    let nat64 = bytes[..12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0];
    globally_routed_unicast || nat64
}

#[cfg(test)]
mod tests {
    use super::is_public_address;

    #[test]
    fn classifies_public_and_private_addresses() {
        assert!(is_public_address("1.1.1.1"));
        assert!(is_public_address("2606:4700:4700::1111"));
        assert!(is_public_address("64:ff9b::808:808"));
        assert!(!is_public_address("10.0.0.1"));
        assert!(!is_public_address("192.168.1.1"));
        assert!(!is_public_address("127.0.0.1"));
        assert!(!is_public_address("fe80::1"));
        assert!(!is_public_address("not-an-address"));
    }
}
