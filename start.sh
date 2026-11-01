#!/bin/bash

# Auto-detect binary path
if [ -n "$1" ]; then
	BIN_PATH="$1"
elif [ -x "./build/linux-release/bin/canary" ]; then
	BIN_PATH="./build/linux-release/bin/canary"
elif [ -x "./canary" ]; then
	BIN_PATH="./canary"
else
	echo -e "\e[01;31m [ERRO] Binario do Canary nao encontrado! Verifique se compilou em ./build/linux-release/bin/canary \e[0m"
	exit 1
fi

# Check if port 7172 is already in use
if command -v fuser &> /dev/null; then
	if fuser 7172/tcp &> /dev/null; then
		echo -e "\e[01;31m [ERRO] Porta 7172 ja esta em uso por outro processo Canary! \e[0m"
		echo -e "\e[01;33m Finalize o processo anterior com: pkill -9 -f 'canary' antes de iniciar novamente. \e[0m"
		exit 1
	fi
fi

if [ -d "logs" ]
then
	echo -e "\e[01;32m Starting server using: $BIN_PATH \e[0m"
else
	mkdir -p logs
fi

if [ ! -f "config.lua" ]; then
	echo -e "\e[01;33m config.lua file not found, new file will be created \e[0m"
	cp config.lua.dist config.lua && ./docker/config.sh --env docker/.env
fi

ulimit -c unlimited
set -o pipefail

while true; do
	START_TS=$(date +%s)
	"$BIN_PATH" 2>&1 | awk '{ print strftime("%F %T - "),
	$0; fflush(); }' | tee "logs/$(date +"%F %H-%M-%S.log")"
	EXIT_CODE=$?
	END_TS=$(date +%s)
	DURATION=$((END_TS - START_TS))

	echo -e "\e[01;33m [Canary] Servidor encerrou com codigo $EXIT_CODE apos ${DURATION}s. \e[0m"

	# Se encerrou em menos de 5 segundos, provavelmente foi erro fatal de socket ou configuracao
	if [ $DURATION -lt 5 ]; then
		echo -e "\e[01;31m [Canary] O servidor fechou muito rapidamente (<5s). Interrompendo loop para evitar loop infinito. \e[0m"
		break
	fi

	# Verificar se a tecla 'q' foi pressionada
	read -t 2 -N 1 -r input
	if [[ "$input" == "q" ]]; then
		break
	fi
done
