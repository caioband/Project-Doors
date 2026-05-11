# Project Doors

Estrutura base de um projeto Roblox em Lua usando Knit, Roact, Wally e Rojo.

## Stack

- Knit para services e controllers
- Roact para UI
- Wally para dependencias
- Rojo para sincronizar com o Roblox Studio

## Estrutura

```text
src/
  client/
    Controllers/
    UI/
    main.client.lua
  server/
    Services/
    main.server.lua
  shared/
    Config.lua
```

## Como usar

1. Rode `aftman install` na raiz do projeto para instalar o toolchain local.
2. Rode `wally install` na raiz do projeto.
3. Rode `rojo serve default.project.json`.
4. Conecte o plugin do Rojo no Studio.

## Dependencias

- `Knit = "sleitnick/knit@1.7.0"`
- `Roact = "roblox/roact@1.4.4"`

## Convencoes

- Os arquivos de codigo do projeto devem usar extensao `.lua`.
- A pasta `.github` nao deve ser versionada neste repositorio.
