
#!/usr/bin/env bash
# Генерируем buildstatus-$buildID.json
# В нем будет вся дополнительная информация такая как: время начала и работы скрипта, buildID, пароль для root  
buildStatus () {
    jq -n --arg $1 "$2" '$ARGS.named' > $3
}

buildStatus root password buildstatus.json  
cat ./buildstatus.json
buildStatus toor password buildstatus.json
cat ./buildstatus.json
