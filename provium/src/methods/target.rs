//! Bind index-word semantics to the effective compiler target, without claiming
//! that a logical array has already been refined to a Rust allocation.
use super::Method;

pub(super) fn pointer_bits(cfg: &str) -> Result<u32, String> {
    let mut width = None;
    for line in cfg.lines().filter(|line| !line.trim().is_empty()) {
        let meta = syn::parse_str::<syn::Meta>(line).map_err(|e| e.to_string())?;
        if !meta.path().is_ident("target_pointer_width") {
            continue;
        }
        let syn::Meta::NameValue(pair) = meta else {
            return Err("target pointer width must be a unique string value".into());
        };
        let syn::Expr::Lit(literal) = pair.value else {
            return Err("target pointer width must be a unique string value".into());
        };
        let syn::Lit::Str(value) = literal.lit else {
            return Err("target pointer width must be a unique string value".into());
        };
        let bits = match value.value().as_str() {
            "16" => 16,
            "32" => 32,
            "64" => 64,
            _ => return Err("unsupported target pointer width".into()),
        };
        if width.replace(bits).is_some() {
            return Err("ambiguous target pointer width".into());
        }
    }
    width.ok_or("effective compiler cfg omits target pointer width".into())
}

pub(super) fn numeric(method: &Method) -> bool {
    method.array.as_ref().is_some_and(|a| a.numeric.is_some())
}

pub(super) fn generate(
    methods: &[Method],
    namespace: &str,
    bits: u32,
    profile: &super::profile::Profile,
) -> String {
    let mut output = format!(
        "namespace {namespace}\nopen Provium.State\ndef target_usize_bits : Nat := {bits}\ntheorem target_usize_valid : Provium.validWidth target_usize_bits = true := by decide\n"
    );
    output.push_str(&format!(
        "def target_overflow_checked : Bool := {}\ndef target_panic_abort : Bool := {}\n",
        profile.overflow_checked, profile.panic_abort
    ));
    for method in methods.iter().filter(|m| numeric(m)) {
        let name = &method.symbol;
        // The divisor remains a checked premise: an arbitrary source literal can
        // fit u64 while not fitting the target's usize.
        output.push_str(&format!(
            "def {name}_target_words (entries : ArrayStore α) (callback : σ) (checked abortOnPanic : Bool) : CallbackRun α σ UInt64 UInt64 :=\n  runNumericWords {name}_ir entries callback target_usize_bits checked abortOnPanic\ntheorem {name}_target_refinement (entries : ArrayStore α) (callback : σ) (checked abortOnPanic : Bool)\n    (capacity : entries.length < 2^target_usize_bits)\n    (divisor : {name}_ir.divisor < 2^target_usize_bits) :\n    {name}_target_words entries callback checked abortOnPanic = {name} entries callback abortOnPanic := by\n  exact runNumericWords_refines _ entries callback target_usize_bits checked abortOnPanic target_usize_valid capacity divisor\n"
        ));
        output.push_str(&format!(
            "def {name}_build_words (entries : ArrayStore α) (callback : σ) : CallbackRun α σ UInt64 UInt64 :=\n  {name}_target_words entries callback target_overflow_checked target_panic_abort\ntheorem {name}_build_refinement (entries : ArrayStore α) (callback : σ)\n    (capacity : entries.length < 2^target_usize_bits)\n    (divisor : {name}_ir.divisor < 2^target_usize_bits) :\n    {name}_build_words entries callback = {name} entries callback target_panic_abort := by\n  exact {name}_target_refinement entries callback target_overflow_checked target_panic_abort capacity divisor\n"
        ));
    }
    for method in methods.iter().filter(|m| m.imperative.is_some()) {
        let name = &method.symbol;
        output.push_str(&format!(
            "def {name}_build (fuel : Nat) (receiver : PureValue) (arguments : List PureValue) : Except Provium.Imperative.Fault (PureValue × PureValue) :=\n  {name} target_usize_bits target_overflow_checked fuel receiver arguments\n"
        ));
    }
    output.push_str(&format!("end {namespace}\n"));
    output
}

#[cfg(test)]
mod tests {
    use super::pointer_bits;

    #[test]
    fn target_width_is_required_unique_and_supported() {
        for bits in [16, 32, 64] {
            assert_eq!(
                pointer_bits(&format!(
                    "unix\ntarget_pointer_width=\"{bits}\"\npanic=\"unwind\""
                )),
                Ok(bits)
            );
        }
        for cfg in [
            "unix",
            "target_pointer_width",
            "target_pointer_width=32",
            "target_pointer_width=\"128\"",
            "target_pointer_width=\"032\"",
            "target_pointer_width=\"32\"\ntarget_pointer_width=\"64\"",
            "target_pointer_width=\"32\"\ntarget_pointer_width=\"32\"",
        ] {
            assert!(pointer_bits(cfg).is_err(), "accepted {cfg}");
        }
    }
}
