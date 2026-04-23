OpenCode en zone air-gap
========================

1) Ne mets pas de clef "$schema" pointant vers https://opencode.ai/... dans OPENCODE_CONFIG_CONTENT
   ou opencode.json : sans reseau, ce fetch echoue. Le fichier opencode-config.schema.json dans ce
   repertoire est une copie locale (telechargee en ligne par online_bundle.sh) pour reference / IDE.

2) Le tarball npm @ai-sdk/openai-compatible est dans npm-tarballs/. Sur la machine offline, installe-le
   la ou OpenCode charge les paquets (souvent sous ~/.opencode), par exemple apres consultation de la
   doc OpenCode pour les providers openai-compatible.

3) Installe aussi le binaire OpenCode lui-meme sur la machine online avant transfert (curl/install officiel),
   puis copie le binaire et ~/.opencode si necessaire — ce script ne redistribue pas le CLI OpenCode.
