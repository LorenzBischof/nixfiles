{
  default = "qwen3.6-moe:35b-a3b";
  # FLM catalog IDs, not Hugging Face repository names. All support vision
  # and tool calling. Gemma 12B offers a different model family for comparison;
  # keep E4B available as a lightweight fallback.
  # https://huggingface.co/google/gemma-4-12B-it#benchmark-results
  models = [
    "qwen3.6-moe:35b-a3b"
    "gemma4-it:12b"
    "gemma4-it:e4b"
  ];
}
