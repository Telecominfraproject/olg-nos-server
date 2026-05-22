.PHONY: all purge

all:
	./dock-run.sh ./build.sh  $(TARGET)

purge:
	cd eve && rm -rf * && rm -rf .*
	@echo Done
