import '../core/catalogue.dart';
import '../core/limits.dart';
import '../online/online.dart';

/// An online AI service that speaks the OpenAI chat-completions API with tools.
class AiService {
  const AiService(this.id, this.label, this.baseUrl, this.keyUrl, this.model);
  final String id, label, baseUrl, keyUrl, model;
}

/// The AI services of 1.x `agent::AI_SERVICES`.
const aiServices = <AiService>[
  // Free tiers: sign up, create a key, no card needed (limits apply).
  AiService(
    'gemini',
    'Google Gemini — free tier',
    'https://generativelanguage.googleapis.com/v1beta/openai',
    'https://aistudio.google.com/app/apikey',
    'gemini-2.5-flash',
  ),
  AiService(
    'groq',
    'Groq — free tier',
    'https://api.groq.com/openai/v1',
    'https://console.groq.com/keys',
    'llama-3.3-70b-versatile',
  ),
  AiService(
    'openrouter',
    'OpenRouter — free models (":free")',
    'https://openrouter.ai/api/v1',
    'https://openrouter.ai/keys',
    'meta-llama/llama-3.3-70b-instruct:free',
  ),
  AiService(
    'github',
    'GitHub Models — free with a GitHub account',
    'https://models.github.ai/inference',
    'https://github.com/settings/personal-access-tokens',
    'openai/gpt-4.1-mini',
  ),
  AiService(
    'cerebras',
    'Cerebras — free tier',
    'https://api.cerebras.ai/v1',
    'https://cloud.cerebras.ai',
    'llama-3.3-70b',
  ),
  AiService(
    'mistral',
    'Mistral — free tier',
    'https://api.mistral.ai/v1',
    'https://console.mistral.ai/api-keys',
    'mistral-small-latest',
  ),
  AiService(
    'sambanova',
    'SambaNova — free tier',
    'https://api.sambanova.ai/v1',
    'https://cloud.sambanova.ai/apis',
    'Meta-Llama-3.3-70B-Instruct',
  ),
  AiService(
    'huggingface',
    'Hugging Face — free monthly credits',
    'https://router.huggingface.co/v1',
    'https://huggingface.co/settings/tokens',
    'meta-llama/Llama-3.3-70B-Instruct',
  ),
  // Paid (billed to the DJ's account).
  AiService(
    'openai',
    'OpenAI (ChatGPT)',
    'https://api.openai.com/v1',
    'https://platform.openai.com/api-keys',
    'gpt-4.1-mini',
  ),
  AiService(
    'deepseek',
    'DeepSeek',
    'https://api.deepseek.com/v1',
    'https://platform.deepseek.com/api_keys',
    'deepseek-chat',
  ),
  AiService(
    'xai',
    'xAI (Grok)',
    'https://api.x.ai/v1',
    'https://console.x.ai',
    'grok-3',
  ),
  AiService(
    'together',
    'Together AI',
    'https://api.together.xyz/v1',
    'https://api.together.xyz/settings/api-keys',
    'meta-llama/Llama-3.3-70B-Instruct-Turbo',
  ),
  AiService('custom', 'Other (OpenAI-compatible server)', '', '', ''),
];

const freeAiServices = {
  'gemini',
  'groq',
  'openrouter',
  'github',
  'cerebras',
  'mistral',
  'sambanova',
  'huggingface',
};

AiService? aiService(String id) =>
    aiServices.where((s) => s.id == id).firstOrNull;

bool isProvider(String id) =>
    const ['off', 'claude', 'local'].contains(id) || aiService(id) != null;

/// Letters, digits and `: . _ - / @` only.
bool validModelName(String v) =>
    v.isNotEmpty &&
    v.length <= 120 &&
    RegExp(r'^[A-Za-z0-9:._\-/@]+$').hasMatch(v);

/// https anywhere, or plain http only on this computer (LM Studio, vLLM…).
bool validCustomUrl(String raw) {
  final v = raw.replaceAll(RegExp(r'/+$'), '');
  if (v.length > 300 || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(v)) return false;
  if (v.startsWith('https://')) {
    final rest = v.substring(8);
    return rest.isNotEmpty && !rest.startsWith('/');
  }
  return [
    'http://127.0.0.1:',
    'http://localhost:',
    'http://[::1]:',
  ].any((p) => v.startsWith(p) && v.length > p.length);
}

const claudeModels = [
  ('claude-opus-5-5', 'Claude Opus 5.5 — most capable (default)'),
  ('claude-sonnet-5-5', 'Claude Sonnet 5.5 — fast and capable, lower cost'),
  ('claude-haiku-5-5', 'Claude Haiku 5.5 — fastest, lowest cost'),
];
const defaultLocalModel = 'qwen2.5:7b';

/// Local models offered in one-click setup: (Ollama name, download size, note).
const localModels = [
  (
    'qwen2.5:7b',
    '4.7 GB',
    'Recommended: best balance of quality and speed (needs about 8 GB of RAM).',
  ),
  (
    'qwen2.5:3b',
    '1.9 GB',
    'Faster and smaller for older or low-memory PCs; less reliable at multi-step tasks.',
  ),
  (
    'llama3.1:8b',
    '4.9 GB',
    'Alternative general model (needs about 8 GB of RAM).',
  ),
];
const defaultLocalUrl = 'http://127.0.0.1:11434';

/// Which model to use and how to reach it (1.x `agent::config`).
LlmConfig llmConfig(Catalogue cat, Secrets secrets) {
  final provider = cat.getSetting('ai_provider') ?? 'off';
  final svc = aiService(provider);
  final String model;
  if (provider == 'local') {
    model = cat.getSetting('ai_local_model') ?? defaultLocalModel;
  } else if (svc != null) {
    model = cat.getSetting('ai_model_${svc.id}') ?? svc.model;
  } else {
    model = cat.getSetting('ai_model') ?? claudeModels.first.$1;
  }
  return LlmConfig(
    provider: provider,
    model: model,
    apiKey: provider == 'claude'
        ? secrets.get('anthropic')
        : (svc != null ? secrets.get('ai_$provider') : null),
    localUrl: cat.getSetting('ai_local_url') ?? defaultLocalUrl,
    baseUrl: svc == null
        ? ''
        : (svc.id == 'custom'
              ? (cat.getSetting('ai_custom_url') ?? '')
              : svc.baseUrl),
    maxTokens: limitOf(cat, 'assistant_tokens') ?? LlmConfig.maxAnswerTokens,
    label: switch (provider) {
      'claude' => 'Anthropic',
      'local' => 'Ollama',
      _ => svc?.label ?? '',
    },
  );
}
