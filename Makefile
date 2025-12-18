bin/restic.sh: restic.sh build.sh
	@sh build.sh $(ARCHIVER)
clean:
	@rm -f bin/restic.sh