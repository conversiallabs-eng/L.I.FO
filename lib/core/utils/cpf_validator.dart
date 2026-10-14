class CpfValidator {
  /// Valida o algoritmo de dígitos verificadores do CPF
  static bool isValid(String? rawCpf) {
    if (rawCpf == null) return false;
    final numbers = rawCpf.replaceAll(RegExp(r'\D'), '');

    if (numbers.length != 11) return false;

    // Rejeita sequências de números repetidos (ex: 11111111111)
    if (RegExp(r'^(\d)\1{10}$').hasMatch(numbers)) return false;

    // Validação do 1º dígito verificador
    int sum1 = 0;
    for (int i = 0; i < 9; i++) {
      sum1 += int.parse(numbers[i]) * (10 - i);
    }
    int remainder1 = (sum1 * 10) % 11;
    if (remainder1 == 10) remainder1 = 0;
    if (remainder1 != int.parse(numbers[9])) return false;

    // Validação do 2º dígito verificador
    int sum2 = 0;
    for (int i = 0; i < 10; i++) {
      sum2 += int.parse(numbers[i]) * (11 - i);
    }
    int remainder2 = (sum2 * 10) % 11;
    if (remainder2 == 10) remainder2 = 0;
    if (remainder2 != int.parse(numbers[10])) return false;

    return true;
  }

  /// Formata número em string CPF (000.000.000-00)
  static String format(String raw) {
    final clean = raw.replaceAll(RegExp(r'\D'), '');
    if (clean.length > 11) return clean.substring(0, 11);
    if (clean.length < 11) return clean;
    return '${clean.substring(0, 3)}.${clean.substring(3, 6)}.${clean.substring(6, 9)}-${clean.substring(9, 11)}';
  }
}
