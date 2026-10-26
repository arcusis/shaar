use bitwarden_crypto::{PublicKey, SymmetricCryptoKey, SymmetricKeyAlgorithm, UnsignedSharedKey};
use std::io::{self, Read};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let public: PublicKey = input
        .trim()
        .parse()
        .map_err(|_| "invalid public fixture key")?;
    let key = SymmetricCryptoKey::make(SymmetricKeyAlgorithm::Aes256CbcHmac);
    #[allow(deprecated)]
    let wrapped = UnsignedSharedKey::encapsulate_key_unsigned(&key, &public)?;
    print!("{wrapped}");
    Ok(())
}
