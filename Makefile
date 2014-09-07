project = oauth2-example
setting_file = ./oauth2-example/config/settings.json

build:
	docker run -v ${PWD}:/workspace -t heroku-haskell /bin/bash -xc 'cd /workspace/ \
	&& cabal update \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config sandbox --sandbox=/workspace/.heroku-cabal-sandbox init \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config install --force-reinstall --dependencies-only \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config configure --builddir=./dist-heroku \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config build ${project} --builddir=./dist-heroku \
	&& strip --strip-unneeded ./dist-heroku/build/${project}/${project}'
	mkdir -p ./dist/build/${project}
	cp ./dist-heroku/build/${project}/${project} ./dist/build/${project}/${project}

build_push:
	docker run -v ${PWD}:/workspace -t heroku-haskell /bin/bash -xc 'cd /workspace/ \
	&& cabal update \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config sandbox --sandbox=/workspace/.heroku-cabal-sandbox init \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config install --dependencies-only \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config configure --builddir=./dist-heroku \
	&& cabal --sandbox-config-file=./heroku.cabal.sandbox.config build ${projcet} --builddir=./dist-heroku \
	&& strip --strip-unneeded ./dist-heroku/build/${project}/${project}'
	mkdir -p ./dist/build/${project}
	cp ./dist-heroku/build/${project}/${project} ./dist/build/${project}/${project}
	git add ./dist/build/${project}/${project}
	git commit -m update
	git push heroku master

run:
	sed -i -e s/ENV_PORT/${PORT}/ ${setting_file}
	sed -i -e s/ENV_OAUTH2_CLIENT_ID/${OAUTH2_CLIENT_ID}/ ${setting_file}
	sed -i -e s/ENV_OAUTH2_CLIENT_SECRET/${OAUTH2_CLIENT_SECRET}/ ${setting_file}
	sed -i -e 's#ENV_OAUTH2_REDIRECT_URI#${OAUTH2_REDIRECT_URI}#' ${setting_file}
	cat ${setting_file}
	./dist/build/${project}/${project}
