restic.sh: restic.script.sh build.sh bin/*
	@sh build.sh $(ARCHIVER)
clean:
	@rm -f restic.sh
