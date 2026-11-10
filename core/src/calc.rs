//! V 模式计算器：以 v 开头打算式（v1+2*3），候选给出结果。
//!
//! 支持 + - * / % ^、括号、小数和负号；×、÷ 也认。只做四则运算这一类，不认函数名。
//! 结果按常见写法格式化：整数不带小数点，小数最多 10 位有效数字并去掉末尾的 0。

/// 算式里允许出现的字符（不含开头的 v）。
pub fn is_expr_char(c: char) -> bool {
    c.is_ascii_digit() || matches!(c, '+' | '-' | '*' | '/' | '%' | '^' | '.' | '(' | ')')
}

/// 计算算式；写错、没写完、除以 0 都返回 None。
pub fn evaluate(expr: &str) -> Option<f64> {
    let chars: Vec<char> = expr
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| match c {
            '×' => '*',
            '÷' => '/',
            other => other,
        })
        .collect();
    if chars.is_empty() {
        return None;
    }
    let mut parser = Parser { chars, pos: 0 };
    let value = parser.expr()?;
    if parser.pos != parser.chars.len() || !value.is_finite() {
        return None;
    }
    Some(value)
}

/// 把结果写成人看的样子：7、0.5、-3.333333333、1e+21 这类太大的用科学计数法。
pub fn format(value: f64) -> String {
    if value == 0.0 {
        return "0".to_string();
    }
    if value.abs() >= 1e15 || value.abs() < 1e-9 {
        return format!("{value:e}");
    }
    let rounded = (value * 1e10).round() / 1e10;
    if rounded.fract() == 0.0 {
        return format!("{}", rounded as i64);
    }
    let digits = 10usize.saturating_sub(rounded.abs().log10().floor().max(0.0) as usize + 1);
    let text = format!("{rounded:.digits$}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    text.to_string()
}

/// 候选：算得出来时是「结果」和「算式=结果」；还没写完时只给算式本身。
pub fn candidates(expr: &str) -> Vec<String> {
    match evaluate(expr) {
        Some(value) => {
            let result = format(value);
            vec![result.clone(), format!("{expr}={result}")]
        }
        None if !expr.is_empty() => vec![expr.to_string()],
        None => Vec::new(),
    }
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn eat(&mut self, c: char) -> bool {
        if self.peek() == Some(c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    // expr := term (('+' | '-') term)*
    fn expr(&mut self) -> Option<f64> {
        let mut value = self.term()?;
        loop {
            if self.eat('+') {
                value += self.term()?;
            } else if self.eat('-') {
                value -= self.term()?;
            } else {
                return Some(value);
            }
        }
    }

    // term := unary (('*' | '/' | '%') unary)*
    fn term(&mut self) -> Option<f64> {
        let mut value = self.unary()?;
        loop {
            if self.eat('*') {
                value *= self.unary()?;
            } else if self.eat('/') {
                let rhs = self.unary()?;
                if rhs == 0.0 {
                    return None;
                }
                value /= rhs;
            } else if self.eat('%') {
                let rhs = self.unary()?;
                if rhs == 0.0 {
                    return None;
                }
                value %= rhs;
            } else {
                return Some(value);
            }
        }
    }

    // unary := ('-' | '+') unary | power
    fn unary(&mut self) -> Option<f64> {
        if self.eat('-') {
            return Some(-self.unary()?);
        }
        if self.eat('+') {
            return self.unary();
        }
        self.power()
    }

    // power := atom ('^' unary)?   右结合：2^3^2 = 2^9
    fn power(&mut self) -> Option<f64> {
        let base = self.atom()?;
        if self.eat('^') {
            let exp = self.unary()?;
            return Some(base.powf(exp));
        }
        Some(base)
    }

    // atom := number | '(' expr ')'
    fn atom(&mut self) -> Option<f64> {
        if self.eat('(') {
            let value = self.expr()?;
            return self.eat(')').then_some(value);
        }
        let start = self.pos;
        while matches!(self.peek(), Some(c) if c.is_ascii_digit() || c == '.') {
            self.pos += 1;
        }
        if start == self.pos {
            return None;
        }
        let text: String = self.chars[start..self.pos].iter().collect();
        text.parse().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn calc(expr: &str) -> Option<String> {
        evaluate(expr).map(format)
    }

    #[test]
    fn precedence() {
        assert_eq!(calc("1+2*3").as_deref(), Some("7"));
        assert_eq!(calc("(1+2)*3").as_deref(), Some("9"));
        assert_eq!(calc("10-4-3").as_deref(), Some("3"));
        assert_eq!(calc("2^3^2").as_deref(), Some("512"));
        assert_eq!(calc("-2^2").as_deref(), Some("-4"));
        assert_eq!(calc("7%3").as_deref(), Some("1"));
        assert_eq!(calc("3×4÷2").as_deref(), Some("6"));
    }

    #[test]
    fn decimals() {
        assert_eq!(calc("1/2").as_deref(), Some("0.5"));
        assert_eq!(calc("0.1+0.2").as_deref(), Some("0.3"));
        assert_eq!(calc("10/3").as_deref(), Some("3.333333333"));
        assert_eq!(calc("1.5*2").as_deref(), Some("3"));
    }

    #[test]
    fn invalid() {
        for expr in ["", "1+", "(1+2", "1/0", "1..2", "abc", "1+2)"] {
            assert_eq!(calc(expr), None, "{expr}");
        }
    }

    #[test]
    fn candidate_list() {
        assert_eq!(candidates("1+2*3"), vec!["7", "1+2*3=7"]);
        assert_eq!(candidates("1+"), vec!["1+"]);
        assert!(candidates("").is_empty());
    }
}
