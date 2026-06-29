sudo apt update
sudo apt install -y curl ca-certificates gh


# claude
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /tmp/claude-code.asc
sudo install -m644 /tmp/claude-code.asc /etc/apt/keyrings/claude-code.asc
echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
  | sudo tee /etc/apt/sources.list.d/claude-code.list
sudo apt update
sudo apt install -y claude-code
